# GitHub Self-Hosted runners @ AWS

This [Terraform](https://www.terraform.io/) module creates the required infrastructure needed to host [GitHub Actions](https://github.com/features/actions) self-hosted, auto-scaling runners on [AWS spot instances](https://aws.amazon.com/ec2/spot/). It provides the required logic to handle the life cycle for scaling up and down using a set of AWS Lambda functions. Runners are scaled down to zero to avoid costs when no workflows are active.

## Motivation

GitHub Actions `self-hosted` runners provide a flexible option to run CI workloads on the infrastructure of your choice. However, currently GitHub does not provide tooling to automate the creation and scaling of action runners. This module creates the AWS infrastructure to host action runners on spot instances. It also provides lambda modules to orchestrate the life cycle of the action runners.

Lambda was selected as the preferred runtime for two primary reasons. Firstly, it enables the development of compact components with limited access to AWS and GitHub. Secondly, it offers a scalable configuration with minimal expenses, applicable at both the repository and organizational levels. The Lambda functions will be responsible for provisioning Linux-based EC2 instances equipped with Docker to handle CI workloads compatible with Linux and/or Docker. The primary objective is to facilitate Docker-based workloads.

A pertinent question may arise: why not opt for Kubernetes? The current strategy aligns closely with the implementation of GitHub's action runners. The chosen approach involves installing the runner on a host where the necessary software is readily available, maintaining proximity to GitHub's existing practices. Another viable option could be AWS Auto Scaling groups. However, this alternative usually demands broader permissions at the instance level from GitHub. Additionally, managing the scaling process, both up and down, becomes a non-trivial task in this scenario.

## Overview

The moment a GitHub action workflow requiring a `self-hosted` runner is triggered, GitHub will try to find a runner which can execute the workload. See [additional notes](docs/additional_notes.md) for how the selection is made. This module reacts to GitHub's [`workflow_job` event](https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#workflow_job) for the triggered workflow and creates a new runner if necessary.

For receiving the `workflow_job` event by the webhook (lambda), a webhook needs to be created in GitHub. The `check_run` option was dropped from version 2.x. The following options to send the event are supported.

- Create a GitHub app, define a webhook and subscribe the app to the `workflow_job` event.
- Create a webhook on enterprise, org or repo level, define a webhook and subscribe the app to the `workflow_job` event.

In AWS an [API gateway](https://docs.aws.amazon.com/apigateway/index.html) endpoint is created that is able to receive the GitHub webhook events via HTTP post. The gateway triggers the webhook lambda which will verify the signature of the event. This check guarantees the event is sent by the GitHub App. The lambda only handles `workflow_job` events with status `queued` and matching the runner labels. The accepted events are posted on a SQS queue. Messages on this queue will be delayed for a configurable amount of seconds (default 30 seconds) to give the available runners time to pick up this build.

The "Scale Up Runner" Lambda actively monitors the SQS queue, processing incoming events. The Lambda conducts a series of checks to determine the necessity of creating a new EC2 spot instance. For instance, it refrains from creating an instance if a build is already initiated by an existing runner or if the maximum allowable number of runners has been reached.

The Lambda first requests a JIT configuration or registration token from GitHub, which is needed later by the runner to register itself. This avoids the case that the EC2 instance, which later in the process will install the agent, needs administration permissions to register the runner. Next, the EC2 spot instance is created via the launch template. The launch template defines the specifications of the required instance and contains a [`user_data`](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html) script. This script will install the required software and configure it. The registration token for the action runner is stored in the parameter store (SSM), from which the user data script will fetch it and delete it once it has been retrieved. Once the user data script is finished, the action runner should be online, and the workflow will start in seconds.

The current method for scaling down runners employs a straightforward approach: at predefined intervals, the Lambda conducts a thorough examination of each runner (instance) to assess its activity. If a runner is found to be idle, it is deregistered from GitHub, and the associated AWS instance is terminated. Presently, no alternative method appears available for achieving a more gradual scaling down process.

To address potential delays in downloading the GitHub Action Runner distribution, a lambda function has been implemented to synchronize the action runner binary from GitHub to an S3 bucket. This ensures that the EC2 instance can retrieve the distribution from the S3 bucket, mitigating the need to rely on internet downloads, which can occasionally take more than 10 minutes.

Sensitive information such as secrets and private keys is stored securely in the SSM Parameter Store. These values undergo encryption using either the default KMS key for SSM or a custom KMS key, depending on the specified configuration.

![Architecture](component-overview.svg)

Permission are managed in several places. Below are the most important ones. For details check the Terraform sources.

- The GitHub App requires access to actions and to publish `workflow_job` events to the AWS webhook (API gateway).
- The scale up lambda should have access to EC2 for creating and tagging instances.
- The scale down lambda should have access to EC2 to terminate instances.

Besides these permissions, the lambdas also need permission to CloudWatch (for logging and scheduling), SSM and S3. For more details about the required permissions see the [documentation](./generated/modules/modules/public/setup-iam-permissions.md) of the IAM module which uses permission boundaries.

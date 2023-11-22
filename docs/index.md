# GitHub Self-Hosted runners @ AWS

This [Terraform](https://www.terraform.io/) module creates the required infrastructure needed to host [GitHub Actions](https://github.com/features/actions) self-hosted, auto-scaling runners on [AWS spot instances](https://aws.amazon.com/ec2/spot/). It provides the required logic to handle the life cycle for scaling up and down using a set of AWS Lambda functions. Runners are scaled down to zero to avoid costs when no workflows are active.

## Motivation

GitHub Actions `self-hosted` runners provide a flexible option to run CI workloads on the infrastructure of your choice. This module creates the AWS infrastructure to host action runners on spot instances. It provides lambda modules to orchestrate the life cycle of the action runners.

Lambda is chosen as the runtime for two major reasons. First, it allows the creation of small components with minimal access to AWS and GitHub. Secondly, it provides a scalable setup with minimal costs that works on repo level and scales to organization level. The lambdas will create based EC2 instances. By default an Amazon linux x64 instances with docker is created. The module supports arm64 and Windows as well.

This module is a native AWS implementation to scale on AWS (spot) instances runners. The module allows you to isolation GitHub jobs on the level of an virtual machine. The module enables features like docker in docker, docker compose and windows. The small control plain reduce the operational overhead Kubernetes can introduce. A good Kubernetes solution is provided by the [ARC Runners](https://github.com/actions/actions-runner-controller) from GitHub.

## Overview

The moment a GitHub action workflow requiring a `self-hosted` runner is triggered, GitHub will try to find a runner which can execute the workload. See [additional notes](docs/additional_notes.md) for how the selection is made. This module reacts to GitHub's [`workflow_job` event](https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#workflow_job) for the triggered workflow and creates a new runner if necessary.

For receiving the `workflow_job` event by the webhook (lambda), a webhook needs to be created in GitHub. The `check_run` option was dropped from version 2.x. The following options to send the event are supported.

- Create a GitHub app, define a webhook and subscribe the app to the `workflow_job` event.
- Create a webhook on enterprise, org or repo level, define a webhook and subscribe the app to the `workflow_job` event.

In AWS an [API gateway](https://docs.aws.amazon.com/apigateway/index.html) endpoint is created that is able to receive the GitHub webhook events via HTTP post. The gateway triggers the webhook lambda which will verify the signature of the event. This check guarantees the event is sent by the GitHub App. The lambda only handles `workflow_job` events with status `queued` and matching the runner labels. The accepted events are posted on a SQS queue. Messages on this queue will be delayed for a configurable amount of seconds (default 30 seconds) to give the available runners time to pick up this build.

The "scale up runner" lambda listens to the SQS queue and picks up events. The lambda runs various checks to decide whether a new EC2 spot instance needs to be created. For example, the instance is not created if the build is already started by an existing runner, or the maximum number of runners is reached.

The Lambda first requests a JIT configuration or registration token from GitHub, which is needed later by the runner to register itself. This avoids the case that the EC2 instance, which later in the process will install the agent, needs administration permissions to register the runner. Next, the EC2 spot instance is created via the launch template. The launch template defines the specifications of the required instance and contains a [`user_data`](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html) script. This script will install the required software and configure it. The registration token for the action runner is stored in the parameter store (SSM), from which the user data script will fetch it and delete it once it has been retrieved. Once the user data script is finished, the action runner should be online, and the workflow will start in seconds.

Scaling down the runners is at the moment brute-forced, every configurable amount of minutes a lambda will check every runner (instance) if it is busy. In case the runner is not busy it will be removed from GitHub and the instance terminated in AWS. At the moment there seems to be no other option to scale down more smoothly.

Downloading the GitHub Action Runner distribution can occasionally be slow (more than 10 minutes). Therefore a lambda is introduced that synchronizes the action runner binary from GitHub to an S3 bucket. The EC2 instance will fetch the distribution from the S3 bucket instead of the internet.

Secrets and private keys are stored in SSM Parameter Store. These values are encrypted using the default KMS key for SSM or passing in a custom KMS key.

![Architecture](docs/component-overview.svg)

Permission are managed in several places. Below are the most important ones. For details check the Terraform sources.

- The GitHub App requires access to actions and to publish `workflow_job` events to the AWS webhook (API gateway).
- The scale up lambda should have access to EC2 for creating and tagging instances.
- The scale down lambda should have access to EC2 to terminate instances.

Besides these permissions, the lambdas also need permission to CloudWatch (for logging and scheduling), SSM and S3. For more details about the required permissions see the [documentation](./modules/setup-iam-permissions/README.md) of the IAM module which uses permission boundaries.

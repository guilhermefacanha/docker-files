# DSF Lab Builder

Create a lab builder for Floci AWS environments with
 - RDS
 - S3
 - S3 + CloudTrail for FAM


# Context

If you look at [floci-local-aws](../floci-local-aws) you will see many scripts to setup AWS env and resources for integration with DSF product
We can setup
 - RDS with CloudWatch integration
 - S3 with CloudTrail
 - Test trafic
 - Generate mock data


# Project

Develop a simple frontend using html+jquery (load everything via cdn) that will connect to a go backend via apis
Project name dsf-lab-builder
Ship everything into a container

RF00 - All scripts and logic can be reused from the sh or made fresh using go, whatever is easier, the system will be informative and interactive, everything should be communicated or informative using good styling like code blocks etc

RF01 - Container should have special priviledges that can create and execute commands inside other containers

RF02 - The home dashboard will read the docker env from server and show all running AWS Envs

RF03 - There will be an option to deploy a new AWS Env (capped at max 5 envs) that will create a new env based on script [update-docker-env.sh](../floci-local-aws/update-docker-env.sh)

RF04 - After a env is created and I click on it from home dashboard system will show details (info about the env, port etc, rds, s3, arn info just like the script returns)
       `- show rds and s3 buckets for fam, show running data generator status and summary` 
       `- create new rds for postgres, mariadb or mysql`
       `- create a new s3 bucket for fam`
       `- test resource`
       `- create a new background generate data for resource that should keep running until is cancelled`
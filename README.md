# Tempo Performance Testing
This project provides tools and configurations for performance testing of **Tempo**, leveraging OpenShift and Kubernetes resources. It includes utilities for managing deployments, running load generators, and monitoring the status of your Tempo setup.
## Table of Contents
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation and Setup](#installation-and-setup)
    - [Namespace Configuration](#namespace-configuration)
    - [Deploying Tempo](#deploying-tempo)
    - [Load Generator Setup](#load-generator-setup)

- [Makefile Usage](#makefile-usage)
- [Contributing](#contributing)
- [License](#license)

## Features
- Deploy **Tempo** in monolithic or stacked configurations.
- Generate and push Docker images for query load generation.
- Simplify resource management with `Makefile` targets for OpenShift/Kubernetes operations.
- Monitor the status and logs of deployed resources.
- Reset and refresh configuration for the load generator.

## Prerequisites
This project requires the following:
- **Docker**: For building and pushing the `query-load-generator` image.
- **OpenShift CLI (oc)** or **Kubernetes CLI (kubectl)**: For interacting with the environment.
- Access to **GitHub Container Registry** or another container registry where the `query-load-generator` image can be pushed.
- A Kubernetes/OpenShift cluster.

## Installation and Setup
### Namespace Configuration
All resources are managed under the defined namespace:
``` bash
NAMESPACE := tempo-perf-test
```
You can modify this in the `Makefile` if needed.
### Deploying Tempo
The project provides two deployment configurations:
1. **Monolithic:**
   Deploy Tempo as a single instance:
``` bash
   make apply-monolithic
```
1. **Stacked:**
   Deploy Tempo with a distributed stack configuration:
``` bash
   make apply-stack
```
### Load Generator Setup
To reset and apply the load generator configuration:
``` bash
make reset-gen
```
This automatically:
- Deletes previous load generator resources.
- Re-creates a `configmap` from `./query-load-generator/queries.txt`.
- Applies the generator YAML file (`generator/` directory).

### Refresh Resources
If you modify any tempo-related resources (e.g., YAML files in the `tempo/` directory), you can apply changes with:
``` bash
make refresh
```
## Makefile Usage
The following `Makefile` commands are available to manage your deployments:

| Target | Description |
| --- | --- |
| **clean** | Deletes the entire namespace and removes all associated resources. |
| **apply-monolithic** | Deploys Tempo in monolithic configuration. |
| **apply-stack** | Deploys Tempo in a stacked configuration. |
| **refresh** | Applies all changes to resources in the `tempo` directory. |
| **reset-gen** | Deletes and recreates the load generator configuration. |
| **pods** | Retrieves all pods in the namespace. |
| **status** | Retrieves the status of all resources in the namespace. |
| **describe** | Describes all pods in the namespace and applies the current `queries.txt` configuration map. |
| **build-push-gen** | Builds and pushes the `query-load-generator` Docker image to the container registry. |
## Example Commands
1. Monitor all pods in the namespace:
``` bash
   make pods
```
1. Deploy a monolithic Tempo setup:
``` bash
   make apply-monolithic
```
1. Build and push the `query-load-generator` image:
``` bash
   make build-push-gen
```
1. Reset the load generator configuration:
``` bash
   make reset-gen
```

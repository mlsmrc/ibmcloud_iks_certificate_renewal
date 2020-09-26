# IBMCloud IKS TLS Certificate Auto-Renewal

[![IKS badge](https://img.shields.io/badge/IBM%20Cloud-Kubernetes%20Service-blue)](https://cloud.ibm.com)
[![Version](https://img.shields.io/badge/version-0.1-yellow)](Changelog.md)

## Problem

Supposing that you have an IBMCloud Kubernetes pod and you use TLS certificate - from IBM Cloud Certificate Manager - to encrypt your connection.

A potentially painful operation could be certificate regeneration which involves:

- TLS Certificate retrieval
- Pod restart

## Resolution

We are going to provide a **[operator](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) CronJob** which manages the TLS certificate renewal.

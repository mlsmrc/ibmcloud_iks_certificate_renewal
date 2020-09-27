# IBMCloud IKS TLS Certificate Auto-Renewal

[![IKS badge](https://img.shields.io/badge/IBM%20Cloud-Kubernetes%20Service-blue)](https://cloud.ibm.com)
[![Base image mlsmrc/ibmcloudcli](https://img.shields.io/badge/Base%20image-mlsmrc/ibmcloudcli-brightgreen)](https://hub.docker.com/mlsmrc/ibmcloudcli)
![Container size](https://img.shields.io/docker/image-size/mlsmrc/ibmcloud_iks_cert_renewal/latest)
[![Version](https://img.shields.io/docker/v/mlsmrc/ibmcloud_iks_cert_renewal/latest)](Changelog.md)

[![Build Status](https://travis-ci.org/mlsmrc/ibmcloud_iks_cert_renewal.svg?branch=master)](https://travis-ci.org/mlsmrc/ibmcloud_iks_cert_renewal)

## Problem

Supposing that you have an IBMCloud Kubernetes pod and you use TLS certificate - from IBM Cloud Certificate Manager - to encrypt your connection.

A potentially painful operation could be certificate regeneration which involves:

- TLS Certificate retrieval
- Pod restart

## Resolution

We are going to provide a container which manages the TLS certificate renewal, performing those actions:

- IBM Cloud login
- old secret backup
- download TLS certificate from IBM Cloud Certificate Manager
- create a new secret based on downloaded certificate
- Kubernetes deployment restart
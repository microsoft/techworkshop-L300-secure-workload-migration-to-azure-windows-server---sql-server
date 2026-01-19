---
title: 'Exercise 00: Lab Setup'
layout: default
nav_order: 2
has_children: true
---

# Exercise 00 - Lab Setup

## Lab Scenario

In this lab, you will perform steps toward migrating Tailspin Toys' on-premises Windows Server and SQL Server workloads to Azure. Tailspin needs a new Windows Server VM created in Azure for hosting their Web application, an on-premises SQL Server database migrated to Azure SQL Managed Instance, secure Windows Server, and an on-premises Windows Server VM to be Azure Arc-enabled.

Tailspin already has a Hub and Spoke network setup in Azure with Azure Bastion for enabling secure remote management of Azure VM using Azure Bastion. The Azure resources provisioned throughout this lab will be deployed into this environment.

In this first exercise, you will deploy the resources needed to simulate the on-prem environment of Tailspin Toys.

## Objectives

After you complete this exercise, you will be able to:

- Validate and register Azure resource providers
- Retrieve your Entra ID account information using the Azure CLI
- Deploy Azure resources using an ARM Template

## Lab Duration

- **Estimated Time:** 30 minutes

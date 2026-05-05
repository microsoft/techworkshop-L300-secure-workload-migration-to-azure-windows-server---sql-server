---
title: 'Exercise 03: Azure Arc-enable on-premises VM'
layout: default
nav_order: 5
has_children: true
---

# Exercise 03 - Azure Arc-enable on-premises VM

## Lab Scenario

For this exercise, you will use a preprovisioned environment to navigate through the tasks and steps. You will **NOT** use your own subscription.

Your coach will provide you with a link to the environment and a registration key.

In the provided environment, you will use an i-SIM to click through the steps associated with Azure Arc-enabling a Windows Server VM that Tailspin has on-premises. This VM is being Arc-enabled since there are no plans to migrate it to Azure, but Tailspin would like to simplify the management of all their VMs in a single place. Azure Arc provides the functionality to manage Azure and on-premises VMs in a single place giving Tailspin Toys exactly what they are looking for to simplify VM management and administration.

## Objectives

After you complete this lab, you will be able to:

- Configure an on-prem VM to be Arc-enabled
- Manage an Arc-enable Virtual Machine via the Azure Portal

## Lab Duration

- **Estimated Time:** 45 minutes

## Pre-Exercise 04 Readiness Check

Before starting Exercise 03, verify that Azure SQL Managed Instance is running.

1. In some lab environments, SQL Managed Instance may be stopped between sessions, and starting it can take 15-30 minutes. Running this check now prevents delays at the start of Exercise 04.

2. From a VS Code terminal, run:

    ```bash
    az sql mi show --resource-group <resource-group-name> --name <sql-mi-name> --query "{state:state, provisioningState:provisioningState}" -o json
    ```

3. If the state is `Stopped`, start it now:

    ```bash
    az sql mi start --resource-group <resource-group-name> --name <sql-mi-name>
    ```

Alternatively, you can also do this in the Azure portal by following the instructions below:

1. Open Azure portal.
2. Go to Resource groups and open your lab resource group.
3. Select your SQL managed instance resource.
4. Check the Status or State value.
5. If state is Stopped, select Start. If state is Ready, continue with Exercise 04.
6. Wait until state changes to Ready, then continue Exercise 04.
  
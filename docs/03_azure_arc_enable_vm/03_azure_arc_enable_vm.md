---
title: 'Exercise 03: Azure Arc-enable on-premises VM'
layout: default
nav_order: 5
has_children: true
---

# Exercise 03 - Azure Arc-enable on-premises VM

## Lab Scenario

In this exercise, you will Azure Arc-enable a Windows Server VM that Tailspin has on-premises. This VM is being Arc-enabled since there are no plans to migrate it to Azure, but Tailspin would like to simplify the management of all their VMs in a single place. Azure Arc provides the functionality to manage Azure and on-premises VMs in a single place giving Tailspin Toys exactly what they are looking for to simplify VM management and administration.

## Objectives

After you complete this lab, you will be able to:

- Configure an on-prem VM to be Arc-enabled
- Manage an Arc-enable Virtual Machine via the Azure Portal

## Lab Duration

- **Estimated Time:** 45 minutes

## Pre-Exercise 04 Readiness Check

Before starting Exercise 03, verify that Azure SQL Managed Instance is running.

In some lab environments, SQL Managed Instance may be stopped between sessions, and starting it can take 15-30 minutes. Running this check now prevents delays at the start of Exercise 04.

In VS Code terminal, run:

```powershell
az sql mi show --resource-group <resource-group-name> --name <sql-mi-name> --query "{state:state, provisioningState:provisioningState}" -o json
```

If the state is `Stopped`, start it now:

```powershell
az sql mi start --resource-group <resource-group-name> --name <sql-mi-name>
```

You can also do this in the Azure portal.  Follow the instructions below:

Open Azure portal.
Go to Resource groups and open your lab resource group.
Select your SQL managed instance resource.
Check the Status or State value.
If state is Ready, continue with Exercise 04.
If state is Stopped, select Start.
Wait until state changes to Ready, then continue Exercise 04.
  
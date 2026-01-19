---
title: 'Exercise 01: SQL Migration to Azure via Arc MI-Link'
layout: default
nav_order: 3
has_children: true
---

# Exercise 01 - SQL database migration

## Lab Scenario

Tailspin Toys relies on mission‑critical analytics and order processing systems that must remain continuously available. Any downtime directly impacts revenue, customer satisfaction, and supply chain operations. To modernize their data estate while meeting strict recovery objectives, Tailspin has chosen to migrate their on‑premises SQL Server workloads to Azure SQL Managed Instance using Azure Arc MI‑Link.

This hybrid approach allows Tailspin to extend Azure management and disaster recovery capabilities to their existing SQL Server environment, ensuring a secure, low‑risk migration path. In this lab, you will step into the role of Tailspin's cloud architect, guiding the migration of their on‑premises database to Azure while validating rollback, failback, and high availability strategies.

## Objectives

After completing this lab, you will be able to:

- Arc-enable an on-premises SQL Server instance and establish connectivity with Azure.
- Configure and validate MI‑Link to replicate databases to Azure SQL Managed Instance for hybrid continuity.
- Perform migration operations including cutover, rollback, and failback to ensure business resilience.
- Upgrade SQL Server to the latest supported version and configure the SQL engine update policy for SQL MI to always-up-to-date.
- Implement database capabilities for modern data workloads, such as vector storage and queries.
- Configure high availability/disaster recovery (HA/DR) strategies using MI-Link to meet Tailspin's recovery objectives.

## Lab Duration

- **Estimated Time:** 45 minutes

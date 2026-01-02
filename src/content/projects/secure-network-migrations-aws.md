---
title: "Secure Firewall & VPN Migrations to AWS"
date: 2025-12-01
summary: "Python workflow to detect expiring certs, automate renewal steps, and raise tickets/alerts."
stack: ["Python", "F5 BIG-IP", "APIs", "Automation"]
---

## Problem
Manual certificate renewals are repetitive and high-risk (outages, last-minute renewals).

## What I built
- Pull cert inventory + expiry dates
- Identify renewals needed in a time window
- Automate renewal workflow steps (guide-driven)
- Create alerting/ticket hook (e.g., ServiceNow)

## Key decisions
- Idempotent workflow: safe to re-run
- Clear logging + dry-run mode
- Config-driven targets

## What I’d do next
- Add Slack/Teams notifications
- Store results in a dashboard
- Expand coverage across environments
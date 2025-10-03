# 🔬 $Mukhtabar^1$ (مُخْتَبَر)

A portable, small-scale, and opinionated computing environment designed for hands-on learning, experimentation, and simulation of IT infrastructure. Mukhtabar can be used as a DevOps learning lab, a starter homelab setup, or a platform to explore and test various software technologies in a controlled environment.

## Setup Overview

Mukhtabar consists of several main components that form the foundation for further customization:

- **Hypervisor Host**

  The physical hardware running Proxmox VE. For this setup, a Dell OptiPlex 3060 Micro is used, equipped with an Intel Core i5-8500T processor (6 cores, 6 threads), 64 GB DDR4 memory, a 2 TB M.2 SSD (dedicated to the TrueNAS ZFS storage pool), a 1 TB SATA SSD (used for the operating system), and a Realtek RTL8111HSD-CG Gigabit Ethernet port. These specifications provide sufficient resources for running Proxmox VE and hosting multiple virtual machines and containers, making the environment suitable for a wide range of homelab and learning scenarios.

- **OPNsense Firewall & Networking**

  The virtualized OPNsense firewall acts as the main gateway for all incoming traffic, except for ports 8006 (Proxmox GUI) and 22 (SSH), which remain accessible for management. It routes all virtual machines and containers running on Proxmox, using two Linux bridges for LAN and WAN connectivity. A point-to-point connection between the WAN interface and the host bridge closely resembles a cloud server setup with a single public IP. While this approach is not ideal for every scenario, it fulfills the goal of creating a portable and flexible computing environment.

  OPNsense manages the entire virtual LAN, providing DHCP and DNS services for all connected systems. VLANs are configured to segment the network, offering isolation and security for different services such as management, storage, and applications. OPNsense also handles IP assignment, DNS resolution, and inter-VLAN routing. Additionally, it provides load balancing and reverse proxy functionality using integrated HAProxy and Nginx, and acts as a private certificate authority (CA) to issue and manage SSL/TLS certificates for internal services.

- **TrueNAS Scale**

  TrueNAS Scale serves as the dedicated storage and backup server within the Mukhtabar environment. It provides centralized file storage, shared volumes, and data protection for all virtual machines and services running on Proxmox. Additionally, TrueNAS Scale can function as a general-purpose NAS server for your home network, though this requires additional configuration and setup, which will be covered in its dedicated guide.

## Guides

To begin setting up this computing environment, follow the guides listed below. Each guide provides detailed, step-by-step instructions to ensure a successful implementation of Mukhtabar's core components.

1. **[Proxmox](guides/proxmox/README.md)**  
   Learn how to install and configure Proxmox VE as the central hypervisor. This guide covers hardware preparation, installation, initial setup, and essential post-installation tasks to create the required virtualization platform.

2. **[OPNsense](guides/opnsense/README.md)**  
   Set up OPNsense as the primary router and firewall for the virtualized network. This guide includes instructions for configuring LAN and WAN bridges, VLANs, DHCP, DNS, load balancing, reverse proxy functionality, and SSL/TLS certificate management.

3. **[GitLab CE](guides/gitlab/README.md)**  
   Install and configure GitLab Community Edition as the main source of truth for infrastructure and DevOps workflows. This guide explains how to integrate GitLab with your environment to manage Infrastructure as Code (IaC) and Configuration Management (CM) tools like Terraform and Ansible.

4. **[TrueNAS Scale](guides/truenas/README.md)**  
   Set up TrueNAS Scale as a dedicated storage and backup server. This guide covers creating shared volumes, configuring snapshots and replication, and using TrueNAS as a general-purpose NAS server for your home network.

Each guide is designed to build upon the previous one, creating a cohesive and functional environment. Once the core components are in place, you can expand Mukhtabar by adding additional modules, such as Kubernetes clusters, Docker Swarm environments, or standalone services, to suit your specific needs.

---

> 💡 $^1$ **Mukhtabar** (Arabic: مُخْتَبَر) is an Arabic word meaning "laboratory" or "a place for testing or experimentation". It derives from the root خ-ب-ر (kh-b-r), which is associated with examining, testing, or gaining knowledge through experience. The word is commonly used in scientific, academic, and technical contexts throughout the Arabic-speaking world.

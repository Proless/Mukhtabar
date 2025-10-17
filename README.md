# 🔬 $Mukhtabar^1$ (مُخْتَبَر)

A portable, small-scale, and opinionated computing environment designed for hands-on learning, experimentation, and simulation of IT infrastructure. This environment can be used as a DevOps learning lab, a starter homelab setup, or a platform to explore and test various software technologies in a controlled environment.

## Overview

The Mukhtabar environment consists of several main components that form the foundation:

- **Hypervisor Host**

  The physical hardware running Proxmox VE. For this setup, a Dell OptiPlex 3060 Micro is used, equipped with an Intel Core i5-8500T processor (6 cores, 6 threads), 64 GB DDR4 memory, a 1 TB SATA SSD (used for the operating system and storage), and a Realtek RTL8111HSD-CG Gigabit Ethernet port. These specifications provide sufficient resources for running Proxmox VE and hosting multiple virtual machines and containers, making the environment suitable for a wide range of homelab and learning scenarios.

- **OPNsense Firewall & Networking**

  The virtualized OPNsense firewall acts as the main gateway for all incoming traffic, except for ports 8006 (Proxmox GUI) and 22 (SSH), which remain accessible for management. It routes all virtual machines and containers running on Proxmox, using two Linux bridges for LAN and WAN connectivity. A point-to-point connection between the WAN interface and the host bridge closely resembles a cloud server setup with a single public IP. While this approach is not ideal for every scenario, it fulfills the goal of creating a portable computing environment.

  OPNsense manages the entire virtual LAN, providing DHCP and DNS services for all connected systems. VLANs are configured to segment the network, offering isolation and security for different services such as management, storage, and applications. OPNsense also handles IP assignment, DNS resolution, and inter-VLAN routing. Additionally, it provides load balancing and reverse proxy functionality using integrated HAProxy and Nginx.

- **GitLab Community Edition**

## Guides

To begin setting up this computing environment, follow the guides listed below. Each guide provides detailed, step-by-step instructions to ensure a successful implementation of Mukhtabar's main components.

1. **[Proxmox](docs/proxmox/README.md)**
   Learn how to install and configure Proxmox VE as the central hypervisor.

2. **[OPNsense](docs/opnsense/README.md)**
   Set up OPNsense as the primary router and firewall for the virtualized network.

3. **[GitLab CE](docs/gitlab/README.md)**
   Install and configure GitLab Community Edition as the main source of truth for infrastructure and GitOps workflows.

Each guide is designed to build upon the previous one, creating a cohesive and functional environment. Once the core components are in place, you can expand the Mukhtabar environment by adding additional modules, such as Kubernetes clusters, Docker Swarm environments, or standalone services, to suit your specific needs.

---

> 💡 $^1$ **Mukhtabar** (Arabic: مُخْتَبَر) is an Arabic word meaning "laboratory" or "a place for testing or experimentation". It derives from the root خ-ب-ر (kh-b-r), which is associated with examining, testing, or gaining knowledge through experience. The word is commonly used in scientific, academic, and technical contexts throughout the Arabic-speaking world.

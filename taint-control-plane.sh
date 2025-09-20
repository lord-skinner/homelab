#!/bin/bash

# Taint the control plane node to prevent scheduling of regular workloads
sudo kubectl taint nodes k3s-arm-node-0 node-role.kubernetes.io/control-plane=true:NoSchedule

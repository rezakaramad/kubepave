package model

// Cluster represents an Argo CD destination cluster and its logical environment.
type Cluster struct {
	Name   string // Argo CD cluster name
	Prefix string // Prefix for the cluster (dev, test, prod, wl, ...)
}

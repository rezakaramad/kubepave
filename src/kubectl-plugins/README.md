# kubectl-plugins

## Name the Plugin Correctly
Kubectl discovers plugins based on this naming pattern:
```
kubectl-<plugin-name>
```

So for your command:
```
kubectl xtenant approve <xtenant>
```

👉 The binary must be named:
```
kubectl-xtenant
```

## Build the Binary

Create the executable:
```
cd xtenant && go build -o kubectl-xtenant
```
Make sure it’s executable:
```
chmod +x kubectl-xtenant
```

## Move it to your PATH

You need to place it somewhere kubectl can find it.

**Option A (recommended):**
```
mv kubectl-xtenant /usr/local/bin/
```

**Option B (user-only):**
```
mv kubectl-xtenant ~/.local/bin/
```

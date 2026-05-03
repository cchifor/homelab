# examples/

Standalone manifests you can `kubectl apply` against the cluster. Not part of the OpenTofu state — apply / scale / delete with `kubectl` independently.

## `dind-pattern-1-statefulset.yaml` — multiple independent docker-in-docker pods

Pattern 1 from the main README's "Running docker compose workloads" section: each pod runs its own `dockerd`, has its own image cache PVC, and is fully isolated from the others. Use when you want strong separation between projects (e.g. one stack per pod) and don't mind each pod re-pulling images.

### Apply

```bash
kubectl apply -f examples/dind-pattern-1-statefulset.yaml
```

Defaults: 2 replicas, 20 GiB image cache PVC each (uses cluster default StorageClass — currently `local-path`; swap to `longhorn` in the manifest once it's re-enabled), pinned to arm64 workers, `privileged: true`, 4 GiB RAM limit per pod.

### Use a single pod

```bash
kubectl -n dind exec -it dind-0 -- sh
# Inside:
/ # docker run --rm hello-world
/ # docker compose up -d
```

### Drop a `compose.yaml` into a pod (Git Bash on Windows)

Git Bash (MSYS) auto-converts `/...` arguments to Windows paths, which mangles `kubectl cp` to remote paths. Two workarounds:

```bash
# (A) Pipe via stdin — path lives INSIDE the quoted remote command, MSYS leaves it alone:
echo "services: { web: { image: nginx, ports: ['8080:80'] } }" \
  | kubectl -n dind exec -i dind-0 -- sh -c 'cat > /workspace/compose.yaml'

# (B) Use kubectl cp with `MSYS_NO_PATHCONV=1` SCOPED to that one command
#     (don't export it globally — it breaks kubectl's kubeconfig path lookup):
MSYS_NO_PATHCONV=1 kubectl -n dind cp ./local-stack/ dind-0:/workspace/local-stack
```

### Run multiple stacks in parallel across pods

Each pod is an independent docker daemon. Use unique compose project names (lowercase only — `-p stack-a`, `-p stack-b`) and you can run as many simultaneous stacks as you have replicas:

```bash
kubectl -n dind exec dind-0 -- sh -c 'cd /workspace && docker compose -p stack-a up -d' &
kubectl -n dind exec dind-1 -- sh -c 'cd /workspace && docker compose -p stack-b up -d' &
wait
```

Verified isolation: `kubectl -n dind exec dind-0 -- docker ps` shows only `stack-a-*` containers, `kubectl -n dind exec dind-1 -- docker ps` shows only `stack-b-*`.

### Scale up / down

```bash
# Add more independent DinD environments:
kubectl -n dind scale statefulset/dind --replicas=5

# Free resources without deleting (PVCs and image caches preserved):
kubectl -n dind scale statefulset/dind --replicas=0
```

### Tear down completely

```bash
kubectl delete namespace dind
```

This deletes pods, PVCs, image caches, and any compose stacks that were running.

### Exposing services from inside a DinD pod

Containers running inside a DinD pod can't be reached via Kubernetes `Service` directly — the docker network is per-pod. Two ways to expose:

1. **`docker compose` port-forward to the pod's network namespace** — bind the container's port to the pod's network with `ports: ["80:80"]`, then create a regular Kubernetes `Service` targeting the DinD pod's port:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata: { name: my-app, namespace: dind }
   spec:
     selector: { statefulset.kubernetes.io/pod-name: dind-0 }
     ports: [ { port: 80, targetPort: 80 } ]
   ```
2. **`kubectl port-forward`** straight to the pod for ad-hoc access:
   ```bash
   kubectl -n dind port-forward dind-0 8080:80
   # browse http://localhost:8080
   ```

### Trade-offs

|   | Pattern 1 (this) | Pattern 2 (one shared dockerd, many clients — see main README) |
|---|---|---|
| Isolation between stacks | strong (separate dockerd per pod) | weak (one dockerd, project-name namespacing only) |
| Image cache | per-pod (re-pulls per replica) | shared (single cache for all clients) |
| Privileged pods | one per replica | one (the daemon) |
| Best for | Different teams/projects, ad-hoc dev | CI runners, frequent compose runs |

If your use case skews toward CI / shared cache, see Pattern 2 in the main README's "Running docker compose workloads" section.

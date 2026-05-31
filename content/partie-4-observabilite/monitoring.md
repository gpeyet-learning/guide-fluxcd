---
title: "Monitoring avec Prometheus et Grafana"
weight: 120
---

FluxCD expose des métriques Prometheus qui permettent de surveiller la santé des réconciliations, les durées, et les taux d'erreur. Ce chapitre déploie la stack de monitoring **via FluxCD lui-même** — une démonstration concrète de GitOps en action.

## Ce que FluxCD expose

Chaque controller FluxCD expose des métriques Prometheus sur le port `8080` (chemin `/metrics`). Les métriques principales :

| Métrique                          | Description                                             |
| --------------------------------- | ------------------------------------------------------- |
| `gotk_reconcile_duration_seconds` | Durée de réconciliation par ressource et par controller |
| `gotk_reconcile_condition`        | État des conditions (Ready, Stalled, Reconciling)       |
| `gotk_suspend_status`             | Ressources suspendues (1 = suspendu)                    |

Ces métriques permettent de construire des dashboards qui répondent à des questions clés :

- Quelle `Kustomization` prend le plus de temps à réconcilier ?
- Y a-t-il des ressources en erreur ou bloquées ?
- Quelle est la fréquence de réconciliation effective ?

## Déployer kube-prometheus-stack via FluxCD

La stack [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) inclut Prometheus, Grafana, et les dashboards pré-configurés pour Kubernetes. Déployons-la via FluxCD.

Ajoutez le HelmRepository pour prometheus-community :

```yaml
# infrastructure/sources/prometheus-community.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: flux-system
spec:
  interval: 1h
  url: https://prometheus-community.github.io/helm-charts
```

Créez le namespace et la HelmRelease :

```yaml
# infrastructure/monitoring/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
```

```yaml
# infrastructure/monitoring/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  interval: 1h
  chart:
    spec:
      chart: kube-prometheus-stack
      version: ">=65.0.0"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
        namespace: flux-system
  install:
    crds: CreateReplace
  upgrade:
    crds: CreateReplace
  values:
    grafana:
      adminPassword: admin # à chiffrer avec SOPS en production
      sidecar:
        dashboards:
          enabled: true
          searchNamespace: ALL
    prometheus:
      prometheusSpec:
        serviceMonitorSelectorNilUsesHelmValues: false
        podMonitorSelectorNilUsesHelmValues: false
```

Ajoutez un `kustomization.yaml` dans `infrastructure/monitoring/` :

```yaml
# infrastructure/monitoring/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
```

Mettez à jour `clusters/local/infrastructure.yaml` pour inclure monitoring :

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure
  prune: true
  wait: true
  timeout: 10m # la stack de monitoring prend du temps
```

## Activer les ServiceMonitors FluxCD

Pour que Prometheus scrape les métriques FluxCD, créez des `ServiceMonitor` :

```yaml
# infrastructure/monitoring/flux-monitors.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: flux-system
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
      - flux-system
  selector:
    matchExpressions:
      - key: app
        operator: In
        values:
          - helm-controller
          - source-controller
          - kustomize-controller
          - notification-controller
          - image-automation-controller
          - image-reflector-controller
  endpoints:
    - port: http-prom
      path: /metrics
      interval: 1m
```

## Committer et déployer

```bash
git add infrastructure/sources/prometheus-community.yaml \
        infrastructure/monitoring/ \
        clusters/local/infrastructure.yaml
git commit -m "feat(monitoring): deploy kube-prometheus-stack via FluxCD"
git push
```

Le déploiement prend environ 5 minutes (beaucoup de ressources à créer). Suivez l'avancement :

```bash
flux get kustomization infrastructure -n flux-system --watch
```

## Accéder à Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```

Ouvrez [http://localhost:3000](http://localhost:3000). Identifiants : `admin` / `admin`.

## Importer le dashboard FluxCD officiel

L'équipe FluxCD maintient des dashboards Grafana officiels. Importez-les via leur ID :

1. Dans Grafana : **Dashboards → Import**
2. Entrez l'ID `16714` (FluxCD Cluster Stats)
3. Sélectionnez votre datasource Prometheus

Vous obtenez une vue complète de toutes vos Kustomizations et HelmReleases avec leurs états, durées de réconciliation, et historique.

## Dashboard sous forme de ConfigMap

Pour gérer les dashboards Grafana via GitOps (comme le reste), stockez-les dans des `ConfigMap` avec le label approprié :

```yaml
# infrastructure/monitoring/dashboard-flux.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: flux-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1" # déclenche la sidecar d'import automatique
data:
  flux-dashboard.json: |
    { ... }   # contenu JSON du dashboard
```

La sidecar Grafana détecte automatiquement ce ConfigMap et importe le dashboard.

> **Mise en pratique** : Observez les métriques FluxCD dans Grafana et identifiez la Kustomization qui a la durée de réconciliation la plus longue.

<details>
<summary>Solution</summary>

Dans Grafana, après avoir importé le dashboard FluxCD officiel (ID `16714`) :

1. Naviguez vers le dashboard **FluxCD Cluster Stats**
2. Dans le panneau **Reconciliation Duration**, triez par durée décroissante

La Kustomization `infrastructure` devrait apparaître en tête — elle déploie `kube-prometheus-stack` qui contient de nombreuses ressources Kubernetes.

Vous pouvez aussi interroger Prometheus directement via l'interface **Explore** :

```promql
# Durée moyenne de réconciliation par controller
histogram_quantile(0.99,
  sum(rate(gotk_reconcile_duration_seconds_bucket[5m])) by (le, kind, name)
)
```

```promql
# Ressources actuellement en erreur
gotk_reconcile_condition{type="Ready", status="False"} == 1
```

```promql
# Taux de réconciliations réussies sur les 30 dernières minutes
sum(rate(gotk_reconcile_duration_seconds_count{success="true"}[30m])) by (kind)
/
sum(rate(gotk_reconcile_duration_seconds_count[30m])) by (kind)
```

Ces requêtes permettent de créer des alertes Prometheus (`PrometheusRule`) qui se déclenchent quand le taux d'erreur de réconciliation dépasse un seuil.

</details>

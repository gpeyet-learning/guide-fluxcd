---
title: "Variables et patches par environnement"
weight: 90
---

Les overlays Kustomize avec des patches JSON fonctionnent, mais ils deviennent verbeux quand il y a beaucoup de différences entre environnements. FluxCD offre un mécanisme plus élégant : les **post-build substitutions**, qui permettent d'injecter des variables dans les manifests après leur rendu par Kustomize.

## Post-build substitutions

Les post-build substitutions permettent de définir des variables dans la `Kustomization` FluxCD et de les injecter dans n'importe quel manifest via la syntaxe `${NOM_VARIABLE}`.

```mermaid
graph LR
    GIT[Manifest Git\ncolor: ${UI_COLOR}] -->|Kustomize render| TEMPLATE[Manifest rendu\ncolor: ${UI_COLOR}]
    VARS[Variables FluxCD\nUI_COLOR: '#27ae60'] -->|post-build substitution| RESULT[Manifest final\ncolor: '#27ae60']
    TEMPLATE --> RESULT
    RESULT -->|kubectl apply| K8S[Kubernetes]
```

## Configurer les variables dans la Kustomization FluxCD

Modifiez `clusters/local/apps.yaml` pour ajouter des variables par environnement :

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps-staging
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/staging
  prune: true
  postBuild:
    substitute:
      ENV_NAME: staging
      PODINFO_COLOR: "#4287f5"
      PODINFO_MESSAGE: "staging — ${ENV_NAME}"
      PODINFO_REPLICAS: "1"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps-production
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/production
  prune: true
  postBuild:
    substitute:
      ENV_NAME: production
      PODINFO_COLOR: "#27ae60"
      PODINFO_MESSAGE: "production — stable"
      PODINFO_REPLICAS: "2"
```

## Simplifier les overlays

Maintenant que les variables sont définies dans la Kustomization FluxCD, les overlays `staging/` et `production/` peuvent être simplifiés. Au lieu de dupliquer des patches, ils utilisent simplement les variables.

Simplifiez `apps/staging/podinfo/kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/podinfo
```

Modifiez `apps/base/podinfo/helmrelease.yaml` pour utiliser les variables :

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
  namespace: podinfo-${ENV_NAME}
spec:
  interval: 10m
  chart:
    spec:
      chart: podinfo
      version: ">=6.7.0"
      sourceRef:
        kind: HelmRepository
        name: podinfo
        namespace: flux-system
  values:
    replicaCount: ${PODINFO_REPLICAS}
    ui:
      color: "${PODINFO_COLOR}"
      message: "${PODINFO_MESSAGE}"
```

Et `apps/base/podinfo/namespace.yaml` :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: podinfo-${ENV_NAME}
```

La base est maintenant un template paramétré. Les overlays ne font plus que pointer vers la base — les variables sont injectées par FluxCD à la réconciliation.

## Variables depuis un ConfigMap ou un Secret

Pour des variables plus complexes ou partagées entre plusieurs Kustomizations, vous pouvez les stocker dans un `ConfigMap` ou un `Secret` et les référencer :

```yaml
# infrastructure/configs/env-staging.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-vars
  namespace: flux-system
data:
  ENV_NAME: staging
  PODINFO_COLOR: "#4287f5"
  PODINFO_REPLICAS: "1"
```

Puis dans la Kustomization FluxCD :

```yaml
postBuild:
  substituteFrom:
    - kind: ConfigMap
      name: cluster-vars
```

Cette approche évite de répéter les variables dans chaque fichier de cluster. Utile quand plusieurs Kustomizations partagent les mêmes valeurs d'environnement.

## Strategic merge patches vs JSON patches

Vous avez deux façons de patcher des manifests Kubernetes avec Kustomize.

### Strategic merge patch

Syntaxe naturelle YAML, fonctionne bien pour les objets imbriqués :

```yaml
# patch-replicas.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  namespace: podinfo-staging
spec:
  replicas: 3
```

Référencé dans `kustomization.yaml` :

```yaml
patches:
  - path: patch-replicas.yaml
```

### JSON patch (RFC 6902)

Plus précis, opérations explicites (`add`, `replace`, `remove`) :

```yaml
patches:
  - patch: |
      - op: replace
        path: /spec/replicas
        value: 3
    target:
      kind: Deployment
      name: podinfo
```

**Quand utiliser lequel** :

| Cas                                       | Recommandé                      |
| ----------------------------------------- | ------------------------------- |
| Modifier une valeur simple                | JSON patch                      |
| Modifier une structure complexe           | Strategic merge                 |
| Supprimer un champ                        | JSON patch (`remove`)           |
| Ajouter un élément à une liste            | Strategic merge (plus intuitif) |
| Patcher plusieurs ressources du même type | JSON patch avec `target`        |

## Committer et vérifier

```bash
git add .
git commit -m "refactor(apps): use post-build substitutions for env config"
git push
```

Vérifiez que les substitutions s'appliquent correctement :

```bash
# Inspecter la Kustomization pour voir les variables
kubectl describe kustomization apps-staging -n flux-system

# Vérifier le namespace créé avec le bon nom
kubectl get namespace podinfo-staging
kubectl get namespace podinfo-production
```

Vérifiez les values effectivement utilisées dans la HelmRelease :

```bash
kubectl get helmrelease podinfo -n podinfo-staging -o yaml | grep -A5 "values:"
```

> **Mise en pratique** : Ajoutez une variable `PODINFO_LOG_LEVEL` différente par environnement (`debug` en staging, `info` en production) et injectez-la dans la HelmRelease.

<details>
<summary>Solution</summary>

**Étape 1** — Ajoutez la variable dans `clusters/local/apps.yaml` :

```yaml
# Dans la Kustomization apps-staging
postBuild:
  substitute:
    ENV_NAME: staging
    PODINFO_COLOR: "#4287f5"
    PODINFO_MESSAGE: "staging"
    PODINFO_REPLICAS: "1"
    PODINFO_LOG_LEVEL: debug

# Dans la Kustomization apps-production
postBuild:
  substitute:
    ENV_NAME: production
    PODINFO_COLOR: "#27ae60"
    PODINFO_MESSAGE: "production"
    PODINFO_REPLICAS: "2"
    PODINFO_LOG_LEVEL: info
```

**Étape 2** — Référencez la variable dans `apps/base/podinfo/helmrelease.yaml`. Le chart podinfo expose `logLevel` dans ses values :

```yaml
values:
  replicaCount: ${PODINFO_REPLICAS}
  logLevel: "${PODINFO_LOG_LEVEL}"
  ui:
    color: "${PODINFO_COLOR}"
    message: "${PODINFO_MESSAGE}"
```

**Étape 3** — Committez et vérifiez :

```bash
git add .
git commit -m "feat(podinfo): add log level per environment"
git push
```

Vérifiez les logs de staging (verbose) vs production (minimal) :

```bash
kubectl logs -n podinfo-staging deploy/podinfo --tail=5
# {"level":"debug",...}

kubectl logs -n podinfo-production deploy/podinfo --tail=5
# {"level":"info",...}
```

</details>

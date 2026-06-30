---
title: "Health checks et remédiation"
weight: 110
---

FluxCD peut surveiller l'état de santé des ressources qu'il déploie et déclencher des actions correctives automatiques en cas d'échec. Ce chapitre configure les health checks et les stratégies de remédiation — rollback automatique, retries, et timeout.

## Health checks dans une Kustomization

Par défaut, FluxCD applique les manifests et passe à la suite sans vérifier que les pods démarrent correctement. Le champ `wait: true` change ce comportement : FluxCD attend que toutes les ressources soient `Ready` avant de marquer la Kustomization comme réussie.

```yaml
---
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
  wait: true # attend que toutes les ressources soient Ready
  timeout: 3m # timeout global — échec si les ressources ne sont pas Ready
```

Vous pouvez aussi définir des health checks explicites sur des ressources spécifiques :

```yaml
healthChecks:
  - kind: Deployment
    name: podinfo
    namespace: podinfo-staging
  - kind: HelmRelease
    name: podinfo
    namespace: podinfo-staging
```

## Remédiation dans une HelmRelease

La `HelmRelease` offre des options de remédiation détaillées pour gérer les échecs d'install et d'upgrade.

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
  namespace: podinfo-staging
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
  install:
    remediation:
      retries: 3 # 3 tentatives d'installation
  upgrade:
    remediation:
      retries: 3 # 3 tentatives d'upgrade
      strategy: rollback # rollback vers la release précédente si toutes les tentatives échouent
      remediateLastFailure: true
  rollback:
    timeout: 5m
    cleanupOnFail: true
  values:
    replicaCount: 1
    ui:
      color: "${PODINFO_COLOR}"
      message: "${PODINFO_MESSAGE}"
```

### Les options de remédiation expliquées

**`install.remediation.retries`** : nombre de tentatives d'installation initiale avant d'abandonner. Si Podinfo n'est jamais installé auparavant et que l'install échoue, FluxCD réessaie ce nombre de fois.

**`upgrade.remediation.retries`** : nombre de tentatives d'upgrade. Un upgrade peut échouer si les nouveaux pods ne démarrent pas (OOMKilled, CrashLoopBackOff, health check échoué, etc.).

**`upgrade.remediation.strategy: rollback`** : si toutes les tentatives d'upgrade échouent, FluxCD execute `helm rollback` pour revenir à la version précédente. La stratégie alternative est `uninstall`.

**`upgrade.remediation.remediateLastFailure: true`** : si le dernier état connu de la release est un échec, FluxCD tente de corriger (rollback ou uninstall) avant de réessayer. Sans ce flag, FluxCD n'intervient pas sur un état d'échec existant.

## Simuler un échec et observer le rollback

Pour tester la remédiation, deployez une version de Podinfo avec une image invalide :

```yaml
# Dans apps/base/podinfo/helmrelease.yaml, ajoutez un patch pour tester
values:
  image:
    tag: "cette-version-nexiste-pas"
```

```bash
git add apps/base/podinfo/helmrelease.yaml
git commit -m "test: deploy invalid podinfo image"
git push
```

Observez FluxCD tenter l'upgrade, échouer, et rollback :

```bash
# Suivre les événements en temps réel
watch flux get helmrelease podinfo -n podinfo-staging
```

Vous verrez la progression :

```text
NAME     REVISION  SUSPENDED  READY   MESSAGE
podinfo  6.7.1     False      False   Helm upgrade failed: ... retrying (1/3)
podinfo  6.7.1     False      False   Helm upgrade failed: ... retrying (2/3)
podinfo  6.7.1     False      False   Helm upgrade failed: ... retrying (3/3)
podinfo  6.7.0     False      True    Release reconciliation succeeded (rolled back)
```

FluxCD a rollback vers `6.7.0`. L'application est de nouveau disponible.

Corrigez en revertant le commit :

```bash
git revert HEAD
git push
```

## Timeout et dépendances

Pour des applications avec des dépendances (une app qui nécessite une base de données disponible), le champ `dependsOn` garantit l'ordre de réconciliation :

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps-staging
  namespace: flux-system
spec:
  dependsOn:
    - name: infrastructure # réconciliée en premier
  path: ./apps/staging
```

FluxCD attend que la Kustomization `infrastructure` soit `Ready` avant de réconcilier `apps-staging`. Si `infrastructure` est en erreur, `apps-staging` ne démarre pas.

## Suspension manuelle

En cas d'incident, vous pouvez suspendre la réconciliation FluxCD pour stabiliser manuellement le cluster sans que FluxCD écrase vos modifications :

```bash
# Suspendre une HelmRelease
flux suspend helmrelease podinfo -n podinfo-staging

# Intervenir manuellement sur le cluster
kubectl set image deployment/podinfo podinfo=ghcr.io/stefanprodan/podinfo:6.7.0 -n podinfo-staging

# Reprendre quand la situation est stable
flux resume helmrelease podinfo -n podinfo-staging
```

La suspension est une mesure temporaire d'urgence — elle ne doit pas rester active longtemps.

> **Mise en pratique** : Configurez une HelmRelease avec un rollback automatique et simulez un échec d'upgrade pour observer le comportement.

<details>
<summary>Solution</summary>

Mettez à jour `apps/base/podinfo/helmrelease.yaml` pour activer la remédiation complète :

```yaml
---
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
  install:
    remediation:
      retries: 2
  upgrade:
    remediation:
      retries: 2
      strategy: rollback
      remediateLastFailure: true
  rollback:
    timeout: 3m
    cleanupOnFail: true
  values:
    replicaCount: ${PODINFO_REPLICAS}
    ui:
      color: "${PODINFO_COLOR}"
      message: "${PODINFO_MESSAGE}"
```

Committez :

```bash
git add apps/base/podinfo/helmrelease.yaml
git commit -m "feat(podinfo): add upgrade remediation with rollback"
git push
```

Attendez la réconciliation (`flux get helmrelease podinfo -n podinfo-staging`).

Maintenant simulez un échec. Introduisez une values invalide (un replicaCount négatif n'est pas accepté) :

```bash
# Patcher directement la HelmRelease dans le cluster (temporaire, sera écrasé par FluxCD)
kubectl patch helmrelease podinfo -n podinfo-staging \
  --type=merge \
  -p '{"spec":{"values":{"replicaCount":-1}}}'
```

Ou committez une valeur invalide dans Git pour déclencher via le workflow normal :

```yaml
# Modifier temporairement apps/base/podinfo/helmrelease.yaml
values:
  replicaCount: -1 # invalide — les Deployments n'acceptent pas de replicas négatifs
```

Observez les tentatives et le rollback :

```bash
kubectl get events -n podinfo-staging --sort-by='.lastTimestamp' | tail -20
```

Vous verrez les tentatives d'upgrade échouer puis le rollback s'exécuter.

Revenez à une configuration valide :

```yaml
values:
  replicaCount: ${PODINFO_REPLICAS}
```

```bash
git add apps/base/podinfo/helmrelease.yaml
git commit -m "fix(podinfo): restore valid replicaCount"
git push
```

</details>

---
title: "Gérer les secrets avec SOPS"
weight: 60
---

Le principe GitOps dit que Git est la source de vérité — mais un mot de passe de base de données ou une clé API ne doit jamais se retrouver en clair dans un dépôt. Ce chapitre montre comment chiffrer les secrets avec SOPS et age, et comment FluxCD les déchiffre automatiquement au déploiement.

## Le problème

Un `Secret` Kubernetes en YAML ressemble à ça :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: podinfo-config
  namespace: podinfo
stringData:
  API_KEY: "ma-cle-secrete-123"
```

Committez ça dans Git, et votre secret est exposé à toute personne ayant accès au dépôt (et potentiellement à l'historique Git pour toujours). Les secrets encodés en base64 dans les Secrets Kubernetes ne sont pas chiffrés — c'est juste de l'encodage, décodable en une commande.

## La solution : SOPS + age

[SOPS](https://github.com/getsentry/sops) (Secrets OPerationS) est un outil de chiffrement de fichiers qui comprend les formats YAML, JSON et .env. Il chiffre uniquement les **valeurs**, pas les clés — ce qui rend les diffs Git lisibles.

[age](https://age-encryption.org/) est un outil de chiffrement moderne et simple. C'est l'algorithme de chiffrement que nous utilisons avec SOPS.

```
# Avant chiffrement
API_KEY: "ma-cle-secrete-123"

# Après chiffrement SOPS
API_KEY: ENC[AES256_GCM,data:7a8b9c...,iv:...,tag:...,type:str]
```

Le fichier chiffré peut être committé sans risque. Seul quelqu'un possédant la clé privée peut déchiffrer.

## Installer les outils

**age** :

```bash
# Linux
curl -Lo age.tar.gz https://github.com/FiloSottile/age/releases/latest/download/age-v1.x.x-linux-amd64.tar.gz
tar xzf age.tar.gz
sudo mv age/age age/age-keygen /usr/local/bin/

# macOS
brew install age
```

**SOPS** :

```bash
# Linux
curl -Lo sops https://github.com/getsentry/sops/releases/latest/download/sops-v3.x.x.linux.amd64
chmod +x sops
sudo mv sops /usr/local/bin/

# macOS
brew install sops
```

## Générer la clé age

```bash
age-keygen -o age.key
```

Ce fichier `age.key` contient votre clé privée. **Ne le committez jamais dans Git.**

```bash
cat age.key
# created: 2026-04-24T10:00:00Z
# public key: age1xy23abc...
# AGE-SECRET-KEY-1...
```

Ajoutez-le à votre `.gitignore` global ou local :

```bash
echo "age.key" >> ~/.gitignore_global
```

Notez la **clé publique** (ligne `# public key:`) — elle sera nécessaire pour chiffrer.

## Créer le Secret Kubernetes dans le cluster

FluxCD a besoin de votre clé privée pour déchiffrer les secrets au moment de les déployer. Transmettez-la au cluster sous forme de Secret Kubernetes :

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=age.key
```

## Configurer FluxCD pour déchiffrer

Indiquez à votre `Kustomization` FluxCD d'utiliser SOPS pour déchiffrer les secrets qu'elle trouve dans le dépôt. Modifiez `clusters/local/apps.yaml` :

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps
  prune: true
  wait: true
  decryption: # ajouté
    provider: sops
    secretRef:
      name: sops-age
```

## Configurer SOPS pour chiffrer automatiquement

Créez un fichier `.sops.yaml` à la racine de votre dépôt `gitops-fleet` pour que SOPS sache automatiquement quelle clé utiliser :

```yaml
# .sops.yaml
creation_rules:
  - path_regex: .*.yaml
    age: age1xy23abc... # votre clé publique ici
```

Committez ce fichier — il ne contient que la clé **publique**, pas de secret.

## Chiffrer un secret

Créez d'abord le secret en clair :

```yaml
# apps/podinfo/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: podinfo-secret
  namespace: podinfo
stringData:
  UI_MESSAGE: "Message secret déployé par FluxCD + SOPS"
  CUSTOM_COLOR: "#8e44ad"
```

Chiffrez-le avec SOPS :

```bash
sops --encrypt --in-place apps/podinfo/secret.yaml
```

Le fichier est maintenant chiffré :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: podinfo-secret
  namespace: podinfo
stringData:
  UI_MESSAGE: ENC[AES256_GCM,data:...,type:str]
  CUSTOM_COLOR: ENC[AES256_GCM,data:...,type:str]
sops:
  age:
    - recipient: age1xy23abc...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
```

Les valeurs sont chiffrées, les clés (`UI_MESSAGE`, `CUSTOM_COLOR`) restent lisibles — les diffs Git ont du sens.

## Référencer le secret dans la HelmRelease

Pour que Podinfo utilise les valeurs du secret, référencez-le via `valuesFrom` dans la HelmRelease :

```yaml
# apps/podinfo/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
  namespace: podinfo
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
    replicaCount: 1
  valuesFrom:
    - kind: Secret
      name: podinfo-secret
      valuesKey: UI_MESSAGE
      targetPath: ui.message
    - kind: Secret
      name: podinfo-secret
      valuesKey: CUSTOM_COLOR
      targetPath: ui.color
```

## Committer et déployer

```bash
git add .sops.yaml apps/podinfo/secret.yaml apps/podinfo/helmrelease.yaml clusters/local/apps.yaml
git commit -m "feat(podinfo): add sops encrypted secret"
git push
```

FluxCD réconcilie, déchiffre le secret à la volée, et injecte les valeurs dans la HelmRelease. Vérifiez que le secret a bien été créé dans le cluster (il est déchiffré côté cluster) :

```bash
kubectl get secret podinfo-secret -n podinfo -o jsonpath='{.data.UI_MESSAGE}' | base64 -d
# Message secret déployé par FluxCD + SOPS
```

> **Mise en pratique** : Ajoutez un second secret qui configure le niveau de log de Podinfo, et vérifiez qu'il est appliqué.

<details>
<summary>Solution</summary>

Podinfo supporte la variable `PODINFO_LOG_LEVEL` (valeurs : `debug`, `info`, `warn`).

Déchiffrez d'abord le fichier secret existant pour l'éditer :

```bash
sops apps/podinfo/secret.yaml
```

SOPS ouvre l'éditeur avec le fichier déchiffré. Ajoutez la nouvelle clé :

```yaml
stringData:
  UI_MESSAGE: "Message secret déployé par FluxCD + SOPS"
  CUSTOM_COLOR: "#8e44ad"
  LOG_LEVEL: "debug"
```

Sauvegardez et fermez l'éditeur. SOPS rechiffre automatiquement.

Modifiez ensuite la HelmRelease pour injecter cette valeur via `envFrom` ou directement dans les values. Pour les variables d'environnement Podinfo non exposées dans les values du chart, utilisez `envFrom` dans un patch :

Créez `apps/podinfo/patch-env.yaml` :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  namespace: podinfo
spec:
  template:
    spec:
      containers:
        - name: podinfo
          envFrom:
            - secretRef:
                name: podinfo-secret
```

Et référencez ce patch dans un `kustomization.yaml` dans `apps/podinfo/` :

```yaml
# apps/podinfo/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.yaml
  - helmrelease.yaml
patches:
  - path: patch-env.yaml
```

Committez, poussez, et vérifiez les logs de Podinfo pour confirmer le mode debug :

```bash
kubectl logs -n podinfo deploy/podinfo | head -5
# {"level":"debug","ts":...}
```

</details>

## Points de vigilance

- La clé privée `age.key` ne doit jamais être dans Git. Stockez-la dans un gestionnaire de secrets (Vault, 1Password, etc.) ou sur votre machine de travail.
- Dans un environnement CI/CD, injectez la clé comme secret d'environnement — pas dans le code.
- `sops --edit` ouvre le fichier déchiffré dans votre éditeur et le rechiffre à la fermeture. C'est la façon recommandée de modifier un secret.
- Tournez régulièrement vos clés age. SOPS supporte plusieurs destinataires — vous pouvez chiffrer pour plusieurs clés simultanément.

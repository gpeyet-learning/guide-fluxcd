---
title: "Gérer les secrets avec SOPS"
weight: 60
---

Le principe GitOps dit que Git est la source de vérité — mais un mot de passe de base de données ou une clé API ne doit jamais se retrouver en clair dans un dépôt. Ce chapitre montre comment chiffrer les secrets avec SOPS et age, et comment FluxCD les déchiffre automatiquement au déploiement.

## Le problème

Un `Secret` Kubernetes en YAML ressemble à ça :

```yaml
---
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

```yaml
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

Pour utiliser correctement votre clé age, `sops` la cherche, dans l'ordre :

1. la variable d'environnement `SOPS_AGE_KEY`, qui contient directement le contenu de la clé
2. la variable d'environnement `SOPS_AGE_KEY_FILE`, qui pointe vers un fichier contenant la clé
3. la variable d'environnement `SOPS_AGE_KEY_CMD`, une commande dont la sortie standard est la clé
4. à défaut, l'emplacement par défaut `~/.config/sops/age/keys.txt`

En générant la clé directement à l'emplacement par défaut, aucune de ces variables n'est nécessaire : `sops` la trouve automatiquement, et des commandes comme `sops edit` fonctionnent sans argument supplémentaire.

Générez-la donc directement là :

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Ce fichier contient votre clé privée. **Ne le committez jamais dans Git** — il n'a de toute façon pas vocation à se trouver dans un dépôt.

```bash
cat ~/.config/sops/age/keys.txt
# created: 2026-04-24T10:00:00Z
# public key: age1xy23abc...
# AGE-SECRET-KEY-1...
```

Notez la **clé publique** (ligne `# public key:`) — elle sera nécessaire pour chiffrer.

## Créer le Secret Kubernetes dans le cluster

FluxCD a besoin d'une clé privée pour déchiffrer les secrets au moment de les déployer — sa **propre** identité age, distincte de la vôtre. `~/.config/sops/age/keys.txt` est réservé à votre usage personnel ; ne le réutilisez pas pour le cluster.

Générez donc une paire dédiée, dans un emplacement temporaire :

```bash
age-keygen -o /tmp/cluster.agekey
# created: 2026-04-24T10:00:00Z
# public key: age1clusterkey...
```

Notez la **clé publique** affichée — elle sera nécessaire pour chiffrer. Chargez la clé privée dans le cluster sous forme de Secret Kubernetes :

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/tmp/cluster.agekey
```

Une fois le Secret créé, supprimez la copie locale : elle n'a plus besoin d'exister en dehors du cluster.

```bash
rm /tmp/cluster.agekey
```

## Configurer FluxCD pour déchiffrer

Indiquez à votre `Kustomization` FluxCD d'utiliser SOPS pour déchiffrer les secrets qu'elle trouve dans le dépôt. Modifiez `clusters/local/apps.yaml` :

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization

metadata:
  name: apps
  namespace: flux-system

spec:
  sourceRef:
    kind: GitRepository
    name: flux-system

  path: ./apps

  interval: 10m
  prune: true
  wait: true
  timeout: 2m

  decryption: # ajouté
    provider: sops
    secretRef:
      name: sops-age
```

## Configurer SOPS pour chiffrer automatiquement

Créez un fichier `.sops.yaml` à la racine de votre dépôt `gitops-fleet` pour que SOPS sache automatiquement quelles clés utiliser. Deux destinataires doivent y figurer dès à présent : votre clé personnelle, pour pouvoir éditer et déchiffrer localement, et celle du cluster, pour que FluxCD puisse déchiffrer au déploiement :

```yaml
---
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1xy23abc..., # vous
      age1clusterkey..., # cluster (Secret sops-age)
```

> Une clé publique age n'a pas de champ commentaire intégré comme les clés SSH. `.sops.yaml` étant du YAML standard, un commentaire `#` en fin de ligne est le seul moyen de noter qui possède quelle clé — purement déclaratif, non vérifié par `sops`.

`encrypted_regex` restreint le chiffrement aux clés `data` et `stringData` : le reste du manifeste (`apiVersion`, `kind`, `metadata`...) reste en clair. Sans cette ligne, SOPS chiffre **toutes** les valeurs du document par défaut — y compris le nom et le namespace du secret, ce qui rend les diffs Git illisibles pour un bénéfice de sécurité nul (ces champs ne sont pas sensibles).

Committez ce fichier — il ne contient que des clés **publiques**, pas de secret.

## Chiffrer un secret

Créez d'abord le secret en clair dans le fichier `apps/podinfo/secret.yaml` :

```yaml
---
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
---
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
    - recipient: age1clusterkey...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
```

Les valeurs sont chiffrées, les clés (`UI_MESSAGE`, `CUSTOM_COLOR`) restent lisibles — les diffs Git ont du sens.

## Référencer le secret dans la HelmRelease

Pour que Podinfo utilise les valeurs du secret, référencez-le via `valuesFrom` dans la HelmRelease `apps/podinfo/helmrelease.yaml` :

```yaml
---
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

Le chart podinfo expose `logLevel` dans ses values. Ajoutez donc une entrée `valuesFrom` supplémentaire dans `apps/podinfo/helmrelease.yaml`, sur le même modèle que `UI_MESSAGE` et `CUSTOM_COLOR` :

```yaml
valuesFrom:
  - kind: Secret
    name: podinfo-secret
    valuesKey: UI_MESSAGE
    targetPath: ui.message
  - kind: Secret
    name: podinfo-secret
    valuesKey: CUSTOM_COLOR
    targetPath: ui.color
  - kind: Secret
    name: podinfo-secret
    valuesKey: LOG_LEVEL
    targetPath: logLevel
```

Committez, poussez, et vérifiez les logs de Podinfo pour confirmer le mode debug :

```bash
kubectl logs -n podinfo deploy/podinfo | head -5
# {"level":"debug","ts":...}
```

</details>

## Gérer plusieurs développeurs

Le champ `age` de `.sops.yaml` accepte plusieurs clés publiques, séparées par des virgules. Chaque secret chiffré l'est alors pour **tous** les destinataires listés — n'importe lequel peut déchiffrer avec sa propre clé privée :

```yaml
---
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1xy23abc..., # vous
      age1bob..., # un collègue
      age1clusterkey...
```

> N'oubliez pas d'y inclure la clé publique du cluster (celle chargée dans le Secret `sops-age`) : sans elle, FluxCD ne peut plus déchiffrer.

### Quand un nouveau développeur arrive sur le projet

1. Il génère sa propre paire de clés en local, comme vu plus haut (`age-keygen -o ~/.config/sops/age/keys.txt`).
2. Il renseigne sa **clé publique** — jamais la privée — dans le fichier `.sops.yaml`.
3. Modifier `.sops.yaml` ne rechiffre pas les secrets déjà existants : leur data key n'a été chiffrée que pour les destinataires présents au moment du chiffrement initial. Mettez donc à jour chaque secret existant :

   ```bash
   sops updatekeys apps/podinfo/secret.yaml
   ```

   Cette commande déchiffre le fichier avec votre clé privée actuelle, puis rechiffre sa data key pour l'ensemble des destinataires désormais listés dans `.sops.yaml` — y compris le nouveau venu. Elle doit être lancée par quelqu'un qui peut déjà déchiffrer le fichier.

4. Committez et poussez le secret mis à jour.

### Quand un développeur quitte le projet

Le retirer de `.sops.yaml` ne suffit pas à lui couper l'accès. Deux commandes entrent en jeu, et elles ne font pas la même chose :

- **`sops updatekeys`** synchronise les destinataires d'un fichier déjà chiffré avec ce qui est déclaré dans `.sops.yaml` — elle ajoute ou retire des entrées. Mais elle ne touche jamais à la **data key** : le secret symétrique qui chiffre réellement le contenu du fichier. Elle se contente de rechiffrer cette même data key pour la nouvelle liste de destinataires.
- **`sops --rotate --in-place`** génère une **nouvelle** data key et rechiffre tout le contenu avec. Mais sur un fichier déjà chiffré, `sops` ne relit pas `.sops.yaml` pour savoir à qui la destiner : elle réutilise les destinataires déjà présents dans les métadonnées du fichier lui-même.

Ces deux limites se combinent mal si on ne fait qu'une seule des deux commandes :

- **`updatekeys` seul** : le développeur parti perd son entrée dans le fichier, mais la data key ne change pas. S'il en a gardé une copie (déchiffrée avant son départ), elle reste valide pour déchiffrer toute version future du fichier qui la réutilise.
- **`--rotate` seul** : la nouvelle data key est rechiffrée pour les destinataires _déjà présents dans le fichier_ — qui incluent encore le développeur parti, puisque `.sops.yaml` n'a pas encore été synchronisé avec le fichier. Il récupère donc une copie valide de la nouvelle data key.

D'où la procédure complète, dans cet ordre précis :

1. Retirez sa clé publique de `.sops.yaml`.
2. `sops updatekeys apps/podinfo/secret.yaml` — retire son entrée des destinataires du fichier. À ce stade, les destinataires restants peuvent encore déchiffrer avec l'**ancienne** data key.
3. `sops --rotate --in-place apps/podinfo/secret.yaml` — génère une nouvelle data key, rechiffrée uniquement pour les destinataires désormais présents dans le fichier (le développeur parti a déjà disparu à l'étape précédente, il n'obtient donc jamais la nouvelle).
4. Committez et poussez.

Répétez ces étapes pour chaque secret du dépôt. Cela n'efface pas ce que le développeur a pu voir en clair avant son départ — si c'est un risque réel, il faut aussi changer la valeur des secrets concernés, pas seulement rechiffrer.

## Effectuer une rotation de sa clé age

Remplacer votre propre clé — après un doute de compromission, ou simplement par hygiène périodique — demande une précaution : générer la nouvelle clé directement à l'emplacement par défaut écraserait l'ancienne avant d'avoir pu vous en servir pour déchiffrer.

Générez-la donc d'abord dans un fichier à part, sans toucher à l'ancienne :

```bash
age-keygen -o ~/.config/sops/age/keys.next.txt
```

Ajoutez sa clé publique à `.sops.yaml`, **en plus** de l'ancienne — les deux sont destinataires en même temps le temps de la transition :

```yaml
age: >-
  age1ancienne..., # vous (ancienne, en transition)
  age1nouvelle..., # vous (nouvelle)
  age1clusterkey..., # cluster (Secret sops-age)
```

Lancez `sops updatekeys` sur chaque secret. L'ancienne clé, toujours à l'emplacement par défaut, permet à `sops` de déchiffrer et de rechiffrer la data key pour les deux destinataires :

```bash
sops updatekeys apps/podinfo/secret.yaml
```

Committez et poussez, puis basculez la nouvelle clé à l'emplacement par défaut :

```bash
mv ~/.config/sops/age/keys.next.txt ~/.config/sops/age/keys.txt
```

Vous n'avez désormais plus que la nouvelle clé privée sur votre machine. Retirez enfin l'**ancienne** clé publique de `.sops.yaml`, et relancez `sops updatekeys` sur chaque secret : `sops` déchiffre cette fois avec la nouvelle clé (désormais à l'emplacement par défaut), et retire l'ancien destinataire. Committez et poussez une dernière fois.

Si la rotation fait suite à un doute de compromission de l'ancienne clé privée — et non une simple hygiène de routine — ajoutez un `sops --rotate --in-place` après cette dernière synchronisation, pour la même raison que lors du départ d'un développeur : `updatekeys` retire l'ancien destinataire, mais ne change pas la data key elle-même. Si l'ancienne clé compromise a permis à quelqu'un d'en récupérer une copie, seule la régénération de la data key l'invalide réellement.

## Points de vigilance

- La clé privée ne doit jamais être dans Git. Stockez-la dans un gestionnaire de secrets (Vault, 1Password, etc.) ou sur votre machine de travail, à l'emplacement par défaut `~/.config/sops/age/keys.txt`.
- Dans un environnement CI/CD, injectez la clé comme secret d'environnement — pas dans le code.
- `sops --edit` ouvre le fichier déchiffré dans votre éditeur et le rechiffre à la fermeture. C'est la façon recommandée de modifier un secret.
- Sauvegardez la clé privée du cluster en dehors du cluster lui-même. Le Secret `sops-age` dans `flux-system` en est la seule copie une fois la clé temporaire supprimée localement — si le cluster est perdu ou reconstruit sans cette sauvegarde, cette clé n'est plus utilisable. Et si personne d'autre n'a été configuré comme destinataire, plus personne ne peut déchiffrer l'historique des secrets déjà committés.
- `.sops.yaml` ne s'applique qu'aux nouveaux chiffrements. Le modifier n'a aucun effet rétroactif sur les fichiers déjà chiffrés : ils gardent leurs propres destinataires embarqués tant que `sops updatekeys` n'a pas été lancé explicitement dessus.
- Un `sops --rotate` fait apparaître tout le fichier comme modifié dans le diff Git, puisque chaque valeur est rechiffrée avec une nouvelle data key — même si aucune valeur secrète n'a réellement changé. C'est attendu, pas une anomalie à investiguer.

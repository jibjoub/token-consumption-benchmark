# Résultats — `impact-ims-db-segment-on-jcl-jobs` (Hades)

> **Conclusion en une phrase.** Avec ou sans le MCP CAST Imaging, les runs renvoient **la même liste de jobs**. Sur ce prompt, l'IA seule fait le travail toute seule avec quelques `grep`. Le MCP ne se distingue que sur le **coût** (~25 % de moins). Il faut donc **durcir le prompt** pour la prochaine campagne — celui-ci ne discrimine rien.

## Le prompt

> *"I want to modify the IMS DB Segment named WK2DETL1, please find all the impacted JCL jobs that can be impacted"*

- **App CAST Imaging** : `Hades` (676 programmes COBOL, 635 copybooks, batch + CICS + IMS — "MYTELCO"/"UNICARE").
- **Sortie structurée forcée** (`json_schema`) : `count` (int), `JCL jobs` (array de strings, format `JOBLIB::JOB-NAME`), `justification` (texte).
- **Fenêtre de collecte** : 2026-09-04 → 2026-09-09.
- **Volume** : 66 runs (19 `without`, 19 `with`, 28 `with-forced`), dont **59 avec une liste de jobs exploitable**.

## Ce qu'on mesure ici — et ce qu'on ne mesure pas

**On ne parle volontairement ni d'accuracy ni de noise sur cette question.** La ground truth n'a pas été validée à la main (contrairement à `calls-to-immdates`, re-vérifiée manuellement et corrigée 239 → 244). Sans référence validée, tout chiffre de type « 92 % de rappel » ne ferait que comparer les runs à une hypothèse, pas à la réalité — autant ne pas le mettre sur une slide.

Ce qu'on mesure à la place, et qui ne demande aucune ground truth : **l'accord entre les trois conditions**. Est-ce que donner CAST Imaging à Claude change ce qu'il répond ? C'est la question qui intéresse le sponsor, et elle se répond en comparant les runs entre eux.

## Le résultat central : les 3 conditions convergent

### Distribution des réponses

Une fois normalisé le préfixe de bibliothèque (`JCLLIB::` / `JOBLIB::` / `Hades::` — variations de forme, même job), voici les listes réellement renvoyées :

| Condition | n | Réponse renvoyée | Runs |
|---|---|---|---|
| `without` | 19 | `IMM038BD`, `IMM041BD`, `IMM044BD`, `IMM207BW`, `IMM381IR` | **11 (58 %)** |
| | | idem + `IMM0INIT` | 3 |
| | | idem + `IMM0INIT`, `IMM384NR`, `IMM385NR` | 3 |
| | | idem + `IMM381BR` | 1 |
| | | `IMM038BD`, `IMM041BD`, `IMM381IR` seulement | 1 |
| `with` | 19 | `IMM038BD`, `IMM041BD`, `IMM044BD`, `IMM207BW`, `IMM381IR` | **17 (89 %)** |
| | | les 4 premiers, sans `IMM381IR` | 2 |
| `with-forced` | 21 | `IMM038BD`, `IMM041BD`, `IMM044BD`, `IMM207BW`, `IMM381IR` | **16 (76 %)** |
| | | les 4 premiers, sans `IMM381IR` | 4 |
| | | les 5 + `IMM381BR` | 1 |

**La réponse majoritaire est strictement la même dans les trois conditions.** Pas « proche », pas « recouvrante » : identique, les cinq mêmes noms.

### Fréquence de chaque job, par condition

| Job | `without` | `with` | `with-forced` | Total |
|---|---|---|---|---|
| `IMM038BD` | 19/19 | 19/19 | 21/21 | **59/59 (100 %)** |
| `IMM041BD` | 19/19 | 19/19 | 21/21 | **59/59 (100 %)** |
| `IMM044BD` | 18/19 | 19/19 | 21/21 | **58/59 (98 %)** |
| `IMM207BW` | 18/19 | 19/19 | 21/21 | **58/59 (98 %)** |
| `IMM381IR` | **19/19** | 17/19 | 17/21 | **53/59 (90 %)** |
| `IMM0INIT` | 6/19 | 0/19 | 0/21 | 6/59 |
| `IMM384NR` | 3/19 | 0/19 | 0/21 | 3/59 |
| `IMM385NR` | 3/19 | 0/19 | 0/21 | 3/59 |
| `IMM381BR` | 1/19 | 0/19 | 1/21 | 2/59 |

### Lecture

- **Un noyau de 5 jobs sort partout** (`IMM038BD`, `IMM041BD`, `IMM044BD`, `IMM207BW`, `IMM381IR`), dans les trois conditions, avec ou sans MCP. Sur 59 runs exploitables, quatre de ces jobs sont cités à ≥98 % et le cinquième à 90 %.
- **Sans MCP, la liste est parfois un peu plus large** : `IMM0INIT`, `IMM384NR`, `IMM385NR` apparaissent dans quelques runs `without` et jamais avec CAST. On ne peut pas les qualifier de « faux positifs » sans vérification manuelle — ce sont des jobs de la même famille (`IMM0INIT` initialise la base `IMMWK2DB`, `IMM384NR`/`IMM385NR` partagent des noms de DD avec la chaîne IMM38xx), donc la question « périmètre d'impact large ou strict ? » est légitimement discutable.
- **Point contre-intuitif** : `IMM381IR` est trouvé **19/19 sans MCP**, contre 17/19 et 17/21 avec. Sur ce job précis, la lecture directe du code est *plus* régulière que le graphe CAST. Rien ne permet donc de dire que le MCP « voit mieux » ici.
- `with-forced` n'apporte rien de plus que `with` : mêmes réponses, un peu plus dispersées.

## Pourquoi ce prompt ne discrimine pas

Parce que la chaîne d'impact est **entièrement traçable au `grep`**, en 4 sauts, chacun étant une correspondance de chaîne littérale :

1. `grep WK2DETL1` sur tout Hades → **9 lignes dans 8 fichiers** : la DBD `IMS/DBD/IMMWK2DB.DBD`, 5 PSB (`IMM0038`, `IMM0041`, `IMM0275`, `IMM3800`, `IMMW2EXT`), `COBOL/PROGRAMS/IMMW2IOS.COB`, un fichier de cartes de contrôle.
2. Les noms de PSB → `grep` dans `JCL/JCLPROCS` → 5 procédures (`PARM=(BMP,…)` / `PARM='DLI,…'`).
3. Les noms de procédures → `grep` dans `JCL/JCLLIB` → 5 jobs.
4. Fin.

**Un seul `grep` sur le nom du segment réduit une application de 676 programmes à 8 fichiers.** Il n'y a aucune indirection à résoudre, aucun nom construit dynamiquement, aucun binding positionnel. C'est exactement le type de question où un graphe de dépendances ne peut pas se différencier d'une recherche textuelle — et c'est ce que les chiffres montrent.

À comparer avec `calls-to-immdates`, où 232 des 244 appels passent par un champ alimenté par copybook et sont **invisibles** au `grep` littéral : là, la différence entre conditions a un sens.

## Coût et tours

| Condition | Coût médian | Coût moyen | Min | Max | Tours (médian) | Tokens output (médian) | Tokens cache-read (médian) |
|---|---|---|---|---|---|---|---|
| `without` | **1.73 $** | 1.76 $ | 1.10 $ | 3.02 $ | 21 | 11 045 | 1 210 783 |
| `with` | **1.34 $** | 1.37 $ | 0.80 $ | 2.95 $ | 47 | 15 859 | 1 676 909 |
| `with-forced` | **1.27 $** | 1.34 $ | 0.60 $ | 2.93 $ | 51 | 16 227 | 1 651 297 |

**Coût total consommé sur cette question : ≈ 89 $** (33.5 $ `without` / 26.1 $ `with` / 29.5 $ `with-forced`).

- CAST coûte **~25 % de moins** en médiane, malgré ~2,4× plus de tours et ~1,4× plus de tokens de sortie : le gain vient du fait qu'on n'ingère pas le code source, remplacé par des tokens de cache réutilisables.
- **C'est le seul écart mesurable entre les conditions sur cette question.** À résultat identique, c'est un argument recevable — mais c'est un argument d'efficacité, pas de capacité.

## Utilisation de CAST Imaging

| Condition | Taux d'usage MCP |
|---|---|
| `without` | 0/19 (normal, tools non fournis) |
| `with` | **18/19 (95 %)** — Claude choisit quasi-systématiquement CAST quand il est disponible |
| `with-forced` | 22/22 (100 %) |

**Outils appelés côté `with`/`with-forced`** : `get_structural_search_function_syntax` (18/19) → `run_structural_search_function` (18/19) → `object_details` (10/19). Pattern stable, répété run après run.

**Outils côté `without`** : `Grep`, `Read` et `Bash` dans **19/19** runs, `Glob` et des sous-agents (`Agent`) dans 12/19 — cohérent avec le coût et la dispersion plus élevés.

L'adoption spontanée à 95 % reste un bon signal produit : quand l'outil est là, il est utilisé sans qu'on ait à le forcer.

## Limites méthodologiques (à connaître avant de rejouer cette question)

1. **Pas de ground truth validée à la main.** D'où l'absence d'accuracy/noise dans ce document. Une reconstruction depuis les sources a été faite (elle converge vers les 5 jobs du noyau, `IMM381IR` inclus, via les PSB `IMM3800` et `IMMW2EXT`) et est consignée dans le champ `notes` de `bench-questions-hades.json`, mais elle n'a **pas** été relue par un humain — à ne pas citer comme référence tant que ce n'est pas fait.
2. **La condition `without` n'était pas cloisonnée au périmètre annoncé.** `run-benchmark-nightly.ps1` pointe `-RepoPath` sur `…\hades-main\hades-main\COBOL`, mais les runs `without` lisent bien `IMS/DBD/IMMWK2DB.DBD`, `JCL/JCLPROCS` et `JCL/JCLLIB` (cités dans 16/19 justifications) : ils sont sortis du répertoire de travail vers les dossiers frères. Ça ne remet pas en cause le constat de convergence, mais si on veut un jour comparer à périmètre égal, il faut le verrouiller explicitement.
3. **Bug de schéma sur cette question.** Le JSON Schema déclare la propriété `JCL-jobs` (tiret) mais exige `JCL jobs` (espace) dans `required`. Résultat : la propriété n'est pas typée, et **59 des 72 réponses renvoient la liste comme string JSON** au lieu d'un array. `score-results.py` sait maintenant absorber les deux formes (`_field_key`, `_as_list`) ainsi que la variation de préfixe (`JCLLIB::` / `JOBLIB::` / `Hades::`). Le schéma lui-même est **laissé tel quel** : 66 runs ont déjà été collectés dessus, le corriger maintenant casserait la comparabilité. À trancher avant la prochaine campagne.
4. **`with-forced` a un taux d'échec technique de 25 %** (7 runs sur 28 sans liste exploitable) :
   - 3 × `API Error 400 — tools.NN.custom.input_schema.properties: Property keys should match pattern '^[a-zA-Z0-9_.-]{1,64}$'` ;
   - 3 × `No 'result' event found in stream-json output` (coupure de flux côté CLI) ;
   - 1 × limite de session atteinte.

   *Piste sur l'erreur 400* : ce motif rejette précisément les clés contenant un espace, et cette question est la seule du jeu à déclarer une propriété avec un espace (`JCL jobs`). À vérifier — mais attention, `with` utilise le même schéma et n'a jamais échoué, donc l'hypothèse « c'est une définition d'outil CAST » reste ouverte.

## Prochaine étape : durcir le prompt

Le but de la campagne est de montrer où CAST Imaging apporte quelque chose. Ce prompt ne peut pas le montrer, puisque `grep` suffit. Pistes concrètes, classées par ce qu'elles cassent :

| Piste | Ce que ça casse pour la recherche textuelle | Exemple sur Hades |
|---|---|---|
| **Viser un objet sans occurrence littérale en source** | Le `grep` d'amorçage ne renvoie rien | Le binding **positionnel** de PCB : `impact-ims-pcb-immmbrdb` (le 3ᵉ PCB de `IMM0038`, atteint uniquement via le copybook générique `IMMDBPCB`, aucun nom de PCB en dur nulle part) — c'est déjà le bon modèle dans le jeu de questions |
| **Ajouter un saut dynamique** | Le nom de la cible est construit à l'exécution | Le motif `IMMDATES` : 232 des 244 sites d'appel passent par un champ alimenté par copybook |
| **Agrandir l'ensemble réponse** | 5 éléments se trouvent par chance ; 60 non | `programs-directly-related-to-EMP-table` (58 programmes), `calls-to-immdates` (244 appels) |
| **Traverser les frontières technologiques** | Impossible de suivre COBOL → DB2 → CICS → Java au `grep` | Hades a du CICS, des MFS et ~2 500 fichiers Java : « quelles transactions en ligne **et** quels points d'entrée Java sont impactés » |
| **Demander une propagation de layout, pas une liste d'objets** | Il faut raisonner sur les structures, pas matcher des noms | « Si j'allonge `WK2DT1KY`, qu'est-ce qui casse ? » — les copybooks `IMM3800D.CPY` / `IMM38RRC.CPY` codent en dur `MAX LENGTH OF IMMWK2DB = 6002` |
| **Contraindre le budget** | L'exploration exhaustive n'est plus gratuite | Plafonner les tours / interdire les sous-agents dans la condition `without` (12/19 runs en ont utilisé) |

**Recommandation** : garder cette question comme **témoin négatif** — elle documente proprement le cas « CAST n'est pas nécessaire », ce qui est une information honnête et utile — et construire la prochaine autour des deux premières lignes du tableau, qui sont les seules à casser structurellement le `grep`.

## À retenir pour la slide

1. **Même résultat avec et sans MCP.** Les trois conditions renvoient la même réponse majoritaire, les cinq mêmes jobs. Quatre d'entre eux sortent dans ≥98 % des 59 runs exploitables, quelle que soit la condition.
2. **L'IA seule y arrive.** Sans CAST, Claude s'en sort avec `Grep` + `Read` + `Bash` (19/19 runs), parce que la chaîne est traçable en 4 `grep` : un seul `grep WK2DETL1` réduit 676 programmes à 8 fichiers.
3. **Le seul écart mesuré est le coût** : ~1.30 $ avec CAST contre 1.73 $ sans, soit ~25 % de moins — un gain d'efficacité, pas de capacité.
4. **Adoption spontanée à 95 %** : quand CAST est disponible sans y être forcé, Claude l'utilise (18/19).
5. **Conclusion opérationnelle : il faut complexifier le prompt.** Cette question est trop facile pour départager les conditions. Les prochaines doivent viser ce que le `grep` ne peut structurellement pas suivre : binding positionnel, appels par nom dynamique, traversée COBOL/CICS/Java, propagation de layout.
6. **Note technique** : `with-forced` a 25 % d'échecs CLI/API sur cette question — à corriger côté outillage avant d'accumuler des runs.

---
*Généré à partir de `results.jsonl` (66 lignes, `question_id = impact-ims-db-segment-on-jcl-jobs`). Les distributions ci-dessus sont recalculables directement depuis ce fichier, sans ground truth. Voir [`README.md`](README.md) pour la méthodologie générale (conditions `without` / `with` / `with-forced`).*

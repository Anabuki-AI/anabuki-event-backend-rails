# origin/main の重複 migration 調査記録

調査日: 2026-09-17
対象: `origin/main` at `14380d0` (`Merge pull request #22 from Anabuki-AI/operator`)

## 結論

`origin/main/db/migrate` には、Rails migration version が同じファイルが2件あります。これはこのクイズAPI PRの変更対象ではありません。Railsはmigration versionごとに `schema_migrations` を管理するため、同じversionを複数のmigrationに割り当てられません。Rails 8.1.3.1 ではmigration contextの構築時に重複versionを検出し、`db:migrate` / `db:prepare` 等が `ActiveRecord::DuplicateMigrationVersionError` で失敗する状態です。

| version | ファイル | 内容 | 導入commit |
| --- | --- | --- | --- |
| `20260917000000` | `20260917000000_add_waiting_heartbeat_to_participant_sessions.rb` | `participant_sessions.waiting_heartbeat_at` を追加し、未revoke session向け部分index `active_waiting_participant_sessions` を作成 | `d38056100f6828649a55fcb4bcb412ce8149f7c9` (`feat: add participant waiting presence heartbeat`, 2026-09-17 01:34:08 +09:00) |
| `20260917000000` | `20260917000000_create_active_storage_tables.rb` | `active_storage_blobs`、`active_storage_attachments`、`active_storage_variant_records` とindex/FKを作成 | `6e99c6c1741d661259c855da15ab5110418e59e0` (`feat: add question image upload, explanation, and target audience`, 2026-09-17 02:11:33 +09:00) |

両commitは同じ親 `39adecd` から分岐しており、前者は PR #21 のmerge `0125ea3`、後者は operator PR のmerge `14380d0` により main に入りました。したがって同じ日時を意図した連番ではなく、並行開発で発生した衝突です。

確認に用いたコマンド:

```bash
git ls-tree -r --name-only origin/main -- db/migrate
git log --follow -- db/migrate/20260917000000_add_waiting_heartbeat_to_participant_sessions.rb
git log --follow -- db/migrate/20260917000000_create_active_storage_tables.rb
git show --no-patch --pretty=raw d380561 6e99c6c
```

このPR自身のquiz migrationは、mainの既存2件には触れず、空いている `20260917000002_create_quiz_events.rb` に番号を変更した。

## 本番DBの確認が必須な理由と影響

`schema_migrations` はversion (`20260917000000`) しか記録しないため、同versionの行があるだけでは、どちらのmigrationを実行済みか、あるいは手動で両方のDDLが反映済みかを区別できません。

まず**本番DBのバックアップを確認した上で**、DBA/本番運用担当が次を確認する必要があります。

```sql
SELECT version
FROM schema_migrations
WHERE version = '20260917000000';

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'participant_sessions'
  AND column_name = 'waiting_heartbeat_at';

SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename = 'participant_sessions'
  AND indexname = 'active_waiting_participant_sessions';

SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN (
    'active_storage_blobs',
    'active_storage_attachments',
    'active_storage_variant_records'
  );
```

追加で、Active Storageのindex/FKも期待どおりか確認すること。影響は状態ごとに異なります。

1. **version行なし・対象DDLもなし**: まだ本番適用されていない可能性が高い。重複したmain migrationの一方を未使用versionへ改名する緊急PRを作り、通常のmigrationとして2件とも適用できる。
2. **version行あり・片方のDDLだけあり**: version行は適用済み側を示すが、Railsはもう一方を同versionのため実行しない。DDLがない側のmigrationだけを新versionへ改名すれば、次のdeployでそのDDLを適用できる。存在する側を改名すると、既存DDLを再実行して `duplicate column` / `relation already exists` 等で失敗する。
3. **version行あり・両方のDDLあり**: 既に両方が反映されている。どちらを改名してもRailsは新versionを未適用とみなしDDLを再実行するため、そのままの改名・deployは失敗する。改名するmigrationの新versionを、DDL検証後に運用手順で `schema_migrations` に記録してskipさせる必要がある（またはDBA承認済みの等価なbaseline手順）。
4. **version行/DDLの組み合わせが上記と一致しない**: 手動DDL、失敗したdeploy、別環境からの復元などを疑う。自動修正せず、実スキーマとdeploy履歴をDBAが照合する。

なお、通常のアプリ実行はmigrationファイルを実行しないため既存プロセスが直ちに壊れるとは限りません。しかし、新環境構築、`db:prepare`、migrationを伴うdeployは停止します。CIでもDB準備を行う構成なら同様に失敗します。

## 安全な修正方法（別の緊急PRで実施）

この問題はmainの緊急修正として、次の順番で扱う。

1. 上記の本番確認とバックアップ可否を運用担当が承認する。
2. 実際に**未適用であることが確認できた側だけ**を、修正PR作成時点で空いている完全な14桁timestampへ改名する。対象DDL・クラス名は変更しない。`schema_migrations` のversionはファイル名から決まるため、timestampはmainと他の未マージPRを再確認して決める。
3. production相当のDBコピーで `db:migrate:status`、`db:migrate`、アプリ起動を検証する。対象DDLが既にある場合は、DDLを再実行しないことを検証する。
4. 両方適用済みなら、DBA承認・バックアップ・ロールバック手順を伴い、改名した方の**新versionのみ**を `schema_migrations` にbaselineとして記録してから（または同一の原子的運用手順で）deployする。手作業のversion記録はmigration実行を抑止するだけなので、必ず実スキーマ照合を先に行う。
5. deploy後に `db:migrate:status`、3つのActive Storage table、heartbeat column/index、アプリのmigration系CIを確認する。

既存migrationの改名・削除はこのPRでは行っていない。上記の本番DB確認に対するユーザー/運用担当の判断が必要である。

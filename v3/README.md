# 麻雀対局記録サイト v3.0 — クラウド試験版

**既存の `index.html`（v2.22）は変更しません。** これは段階的な開発用機能です。

## ファイル

- `v3/cloud.html`：クラウド接続・メールログイン・ルーム作成・招待・スナップショット読込/書出し
- `supabase/v3_schema.sql`：非公開ルーム、RLS、権限付きRPC、24時間/1回限り招待、版番号管理
- `v3/migration-check.html`：既存バックアップの形式検査
- `v3/import-preview.html`：ローカルJSONバックアップ間の衝突検査と統合

## Supabase の初期設定（プロジェクト所有者）

1. Supabaseの新規プロジェクトを準備する（既存の本番DBにいきなり適用しない）。
2. SQL Editor で `supabase/v3_schema.sql` を実行する。失敗した場合はメッセージを確認し、再実行を繰り返す前に原因を解決する。
3. Authentication > Providers で Email のOTP/マジックリンクを有効にする。送信制限を確認する。
4. Authentication > URL Configuration で実際のクラウド試験版URLを Redirect URLs に追加する（例：`https://kura765.github.io/mahjong-record/v3/cloud.html`）。
5. Supabase の Project URL と **Publishable key（または anon key）** をクラウド試験画面に入力する。**service_role や secret key は絶対に使用しない。**
6. 2つの別アカウントで作成者と閲覧者の権限を検証する。招待リンクは1回使用すると再利用できない。
7. この段階では Supabase Realtime publication は設定しない。ルーム一覧更新は手動。

## クラウドに保存するデータ

`mahjong_room_matches` は `room_id` と `match_key` を複合キーとし、JSONBの `payload` に `{kind,match}` を記録します。kind は `completed` / `suspended` / `active` です。各更新は `mahjong_save_match` RPC経由のみ許可され、版番号の競合をチェックし、履歴テーブルに記録します。

招待トークンは64文字のランダムな16進文字列で、DBにはSHA-256ハッシュのみ保存します。招待は作成から24時間有効・使用は1回限り。メンバーは閲覧専用です。

## 既知の未実装事項と注意

- **Supabaseプロジェクトの作成・SQL実行はまだ未実施**。GitHubにファイルを登録した段階です。
- クラウドへの自動同期、Realtimeによる他端末への自動反映、既存v2.22の対局入力UI統合は未実装。
- バックアップ取り込みは前検査後に各半荘を順次追加します。途中でネットワークが切れた場合は一部のみ保存され得ます。同じファイルを再選択し、重複を再確認してください。
- 既存のクラウド側に同IDかつ異なる内容の半荘があれば上書きを拒否します。
- クラウド試験画面のJSON書き出しはルームの保存済みスナップショット形式であり、v2.22の全体バックアップとは異なります。そのままv2.22の「バックアップ読み込み」には渡さないでください。
- 作成者しか更新できない仕組みです。参加者の閲覧専用制約はDB側のRLSとRPCで実装しています。公開利用前に権限/招待/データ移行の実機テストが必要です。
- ローカルストレージの設定保存は公開用のSupabase URL/キーのみ。個人のservice_role/secret keyを記録しないでください。

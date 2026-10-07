# 公開リポジトリからSaladCloudで4モデルのComfyUIを開く手順

対象は公開リポジトリ `aoikonn129dhja/qwen_vast_sh`。GHCRの4モデルのイメージもPublicに設定し、Saladではregistry認証なしで使用する。

## 1. GitHubで4モデルのイメージを作る（共通・初回）

1. GitHubにリポジトリ所有者の **aoikonn129dhja**（または書き込み権限のあるアカウント）でログインし、[GitHubリポジトリ](https://github.com/aoikonn129dhja/qwen_vast_sh)を開く。
2. **Actions** をクリックする。
3. 左側の **Build Salad images** を選ぶ。
4. 実行一覧の上にある **Run workflow** をクリックし、Branchを **main** にして、開いたメニュー内の **Run workflow** をクリックする。
5. 実行結果を開き、4つの `build` ジョブがすべて緑のチェックになるまで待つ。
6. 各モデルのジョブを開き、`docker/build-push-action` のログから `ghcr.io/` で始まり、`:sha-` とコミットSHAで終わるイメージ指定をコピーして保存する。

| 使用するモデル | ログを開くジョブ | イメージ名に含まれる部分 | SaladのGroup名に入力する名前 |
|---|---|---|---|
| Qwen Rapid AIO NSFW v19 | `build (qwen-rapid-aio-nsfw-v19)` | `salad-qwen-rapid-aio-nsfw-v19` | `qwen-rapid-v19` |
| Qwen Image Edit 2509 | `build (qwen-image-edit-2509)` | `salad-qwen-image-edit-2509` | `qwen-edit-2509` |
| Qwen Image Edit 2511 | `build (qwen-image-edit-2511)` | `salad-qwen-image-edit-2511` | `qwen-edit-2511` |
| LTX 2.3 Uncensored v1.4 Q4 | `build (ltx-2.3-uncensored-v1.4-q4)` | `salad-ltx-2.3-uncensored-v1.4-q4` | `ltx-23-q4` |

**Run workflowが表示されない場合**は、右上のプロフィールからログイン中のアカウントを確認し、所有者または書き込み権限のあるアカウントに切り替える。ページを再読み込みし、左側の **Build Salad images** を選び直す。公開リポジトリでも、手動実行には書き込み権限が必要。[GitHub公式手順](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

失敗したジョブのイメージは使わず、そのジョブのエラーを確認する。

## 2. GHCRの4モデルのイメージをPublicにする（共通・初回）

1. GitHubで **aoikonn129dhja** のプロフィールを開き、**Packages** を選ぶ。
2. 手順1で作成した対象モデルのpackageを開く。
3. **Package settings** を開く。
4. Visibilityを確認する。Privateの場合は **Danger Zone → Change visibility → Public** を選び、package名を入力して公開を確定する。既にPublicなら変更しない。
5. 使用する4モデルそれぞれで同じ操作を行う。

6. 4つのpackageすべてで **Public** と表示されていることを確認する。リポジトリが公開でも、GHCR packageの公開状態は別に確認する。[GitHubのpackage公開設定](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)

## 3. Saladでモデル用Container Groupを作る（モデルごと）

1. [SaladCloud Portal](https://portal.salad.com)にログインする。
2. Organizationを選択する。未作成ならOrganizationを作成し、Billingからクレジットを追加する。
3. 使用するProjectを選択する。未作成ならProjectを作成する。
4. **Deploy a Container Group** をクリックし、**Custom** を選ぶ。
5. 使用するモデルを手順1の表から選び、Group名と、保存したそのモデルのイメージ指定を入力する。
6. 次の設定を入力する。

| 設定項目 | 入力内容 |
|---|---|
| Name | 手順1の表にある対象モデルのGroup名 |
| Image Source | 対象モデルのログからコピーしたイメージ指定全体。`:sha-…` まで含める |
| Registry authentication / Credentials | 設定しない。Username・Password・tokenは入力しない |
| Replicas | `1` |
| CPU | 初期設定として `4 vCPU` |
| RAM | 初期設定として `32 GB` 以上 |
| GPU | NVIDIA GPUを選択。初期設定としてVRAM `32 GB` 以上 |
| Disk Space | `50 GB` 以上の追加空き容量を選択 |
| Environment Variables | 追加しない |
| Command / Arguments | 上書きしない |
| Startup / Liveness Probe | 追加しない |

7. **Add Container Gateway** をクリックする。
8. GatewayのPortに **8189** を入力し、Authenticationを **Disabled** にする。
9. **Configure** をクリックしてGateway設定を保存する。
10. **Auto Start** を有効にし、**Deploy** をクリックする。

画面操作は [Salad公式のデプロイ手順](https://docs.salad.com/container-engine/tutorials/quickstart)、追加空き容量の指定は [Disk Space](https://docs.salad.com/container-engine/explanation/container-groups/disk-space) を参照。

## 4. モデルの準備を待ち、ComfyUIを開く（モデルごと）

1. 作成したContainer Groupの詳細画面を開く。
2. **Container Logs** タブを開く。
3. モデルのダウンロードと起動が終わるまで待つ。ログに `Starting server` と `127.0.0.1:8188` の起動案内が出ることを確認する。
4. 詳細画面のContainer Gatewayに表示される **HTTPS URL** をコピーする。
5. ブラウザの新しいタブにURLを貼り付けて開く。末尾にポート番号は追加しない。
6. ComfyUIの画面が表示されたら完了。

画面が表示されない場合は **Container Logs** に戻る。ダウンロード中なら待ち、エラーがあればその内容を確認する。[Container Logsの開き方](https://docs.salad.com/container-engine/explanation/container-groups/container-logs)

## 5. 4モデルそれぞれで開く

| 開きたいモデル | 行う操作 |
|---|---|
| Qwen Rapid AIO NSFW v19 | Rapidのイメージで `qwen-rapid-v19` を作成し、手順4でそのGroupのGateway URLを開く |
| Qwen Image Edit 2509 | 2509のイメージで `qwen-edit-2509` を作成し、手順4でそのGroupのGateway URLを開く |
| Qwen Image Edit 2511 | 2511のイメージで `qwen-edit-2511` を作成し、手順4でそのGroupのGateway URLを開く |
| LTX 2.3 Uncensored v1.4 Q4 | LTXのイメージで `ltx-23-q4` を作成し、手順4でそのGroupのGateway URLを開く |

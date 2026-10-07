# SaladCloudで4モデルのComfyUIを開く操作手順

2026年10月7日の画面操作に基づく。Organizationは `image-video-gen`、Projectは `Default` を使用する。

## 現在の到達点

- GitHub Actionsの4モデルのbuildは成功済み。イメージ指定は `salad_image_references.txt` に保存済み。
- GHCRの4イメージはPublic確認済み。残り3モデルでもビルド・公開設定をやり直す必要はない。
- `qwen-edit-2511` はContainer Group作成済み。最後に確認した画面は **PREPARING / 0 / 1 Replicas Running**。ComfyUIの画面表示はまだ確認していない。
- 残りは `qwen-rapid-v19`、`qwen-edit-2509`、`ltx-23-q4` を作成する。

## 1. 作成するモデルとイメージを選ぶ

各モデルのContainer Groupを、同じ `Default` Project内に1つずつ作る。Group名とImage Sourceだけをモデルごとに変更し、以降の操作は共通。

| モデル | Container Group Name |
|---|---|
| Qwen Rapid AIO NSFW v19 | `qwen-rapid-v19` |
| Qwen Image Edit 2509 | `qwen-edit-2509` |
| Qwen Image Edit 2511（作成済み） | `qwen-edit-2511` |
| LTX 2.3 Uncensored v1.4 Q4 | `ltx-23-q4` |

**Qwen Rapid v19のImage Name**

```text
ghcr.io/aoikonn129dhja/qwen_vast_sh/salad-qwen-rapid-aio-nsfw-v19:sha-22651bc9474f367711e0c2c31cef65708ce8c050
```

**Qwen Edit 2509のImage Name**

```text
ghcr.io/aoikonn129dhja/qwen_vast_sh/salad-qwen-image-edit-2509:sha-22651bc9474f367711e0c2c31cef65708ce8c050
```

**Qwen Edit 2511のImage Name（作成済みGroupの確認用）**

```text
ghcr.io/aoikonn129dhja/qwen_vast_sh/salad-qwen-image-edit-2511:sha-22651bc9474f367711e0c2c31cef65708ce8c050
```

**LTX 2.3 Q4のImage Name**

```text
ghcr.io/aoikonn129dhja/qwen_vast_sh/salad-ltx-2.3-uncensored-v1.4-q4:sha-22651bc9474f367711e0c2c31cef65708ce8c050
```

上のコード欄の1行全体をコピーする。`salad_image_references.txt` からコピーする場合は、引用符の内側だけをコピーし、変数名や引用符を含めない。

## 2. Container Groupの作成画面を開く

1. [SaladCloud Portal](https://portal.salad.com)にログインする。
2. Organizationを **image-video-gen** にする。
3. 左上のProject選択を **Default** にする。Projectを新しく作る必要はない。
4. 左の **Container Groups** を開き、作成ボタンを押す。Groupがない画面では **Deploy a Container Group** と表示される。
5. **Starting Point** で **Custom** を選ぶ。
6. **Cloud** の画面を進め、**Priority and GPU** を開く。

## 3. Priority and GPU / Resourcesを入力する

1. **Priority** は **Lowest** を選ぶ。
2. GPUは **RTX 5090 (32 GB)** だけを選ぶ。他のカードが緑色になっている場合はクリックして解除する。
3. **Next Step** を押す。
4. **Resources** で次の値を入力し、**Next Step** を押す。

| 項目 | 入力値 |
|---|---|
| CPU | `4 vCPU` |
| Memory / RAM | `16 GB` |
| Disk Space | 追加空き容量 `50 GB` 以上を目安に選ぶ |

CPU 4 vCPU・RAM 16 GB・RTX 5090は2511作成画面で確認した値。16 GBでのモデル読み込み・生成は未確認。メモリ不足のエラーで停止した場合は、Groupの **Edit** からRAMを32 GBへ増やす。Disk Spaceの実際の選択値は今回の画面では未確認なので、作成時に確認する。

## 4. Container Configurationを入力する

1. **Container Group Name** に手順1の対象モデルの名前を入力する。
2. **Image Source → Edit** を押す。
3. 次の値を入力して **Configure** または **Save** を押し、設定画面を閉じる。

| 項目 | 入力・選択 |
|---|---|
| Image Name | 手順1の対象モデルの `ghcr.io/...:sha-...` 全体 |
| Is it in a public or private registry? | **Public Registry** |
| What Service Are You Using? | **GitHub Container Registry** |

4. **Image Source** に入力したイメージ名が表示されることを確認する。
5. **Replicas** は `1` にする。
6. **Scheduled Scaling** は追加しない。
7. **Environment Variables** は **No environment variables set** のままにする。
8. **Command** は **None Configured** のままにする。
9. **Next Step** を押す。

## 5. Networking / Container Gatewayを設定する

1. **Add Container Gateway** を押す。
2. 次の値を入力する。

| 項目 | 入力・選択 |
|---|---|
| Enable Container Gateway. I've set up my container to support IPv6. | チェックを入れる |
| Port | `8189` |
| Use Authentication? | **No** |
| Load Balancer Algorithm | **Least Number Of Connections** |
| Limit each server to a single, active request. | チェックしない |
| Client Request Timeout | `100000` ミリ秒 |
| Server Response Timeout | `100000` ミリ秒 |

3. **Configure** を押して保存する。
4. **Outbound Requests** はそのままにし、**Next Step** を押す。

認証をNoにしたURLは、URLを知っている人がアクセスできる。作成したイメージはIPv6の8189番ポートを受け付ける設定済み。

## 6. Health Probes & LoggingからDeployする

1. 次の設定を維持する。

| 項目 | 設定 |
|---|---|
| Startup Probe | **Disabled** |
| Liveness Probe | **Disabled** |
| Readiness Probe | **Disabled** |
| External Logging Services | **None / Disabled** |

Probeの編集欄にPort `1` やCommand `cat` が表示されても、有効化しない。Disabledの状態では使用されない。

2. **Allocated Resources** で、1 Replica・4 vCPU・16 GB・RTX 5090 (32 GB)・Lowestを確認する。
3. **Estimated Cost** を確認する。2511作成時の表示は合計 **$0.25 per hour**。
4. 作成だけ行う場合は、**Autostart container group once image is pulled** のチェックを外す。すぐ起動する場合はチェックを入れる。残り3モデルを先に作成しておく場合は、チェックを外して作成する。
5. **Deploy** を押す。
6. **Continue without enabling a Readiness Probe?** が表示されたら、**Continue** を押す。
7. 対象のGroup名の詳細画面が開き、**PREPARING** と表示されることを確認する。

Autostartが有効だと準備後に自動起動する。割り当て待ち・Dockerイメージのダウンロード中は課金されず、コンテナ稼働中は画像を生成していなくても課金される。コンテナ内で行うモデルのダウンロードは、Dockerイメージのダウンロードとは別。[課金仕様](https://docs.salad.com/container-engine/explanation/billing-pricing/billing)

## 7. 起動してComfyUIを開く

2511はここから続ける。残り3モデルも作成後に同じ操作を行う。

1. 対象のContainer Group詳細画面を開く。
2. **PREPARING** が終わるまで待つ。
3. Autostartを外して作成した場合は、押せるようになった **Start** を押す。
4. **Container Logs** タブを開く。
5. モデルのダウンロードが終わり、ログに `Starting server` と `127.0.0.1:8188` の起動案内が出るまで待つ。
6. 画面上部の **Access Domain Name (Open)** の右端にあるコピーアイコンを押す。
7. ブラウザの新しいタブにコピーしたHTTPS URLを貼り付けて開く。末尾に `:8188` や `:8189` は追加しない。
8. ComfyUIの画面が表示されることを確認する。
9. 使用を終えたら生成物を保存し、Container Groupの **Stop** を押す。ブラウザを閉じるだけでは停止しない。

URLを開いても表示されない場合は **Container Logs** に戻る。ダウンロード中なら待ち、エラーが出ていればその内容を確認する。

## 8. 新しいイメージを作った場合だけ行う操作

現在保存済みの4イメージを使う場合、この操作は不要。

1. [GitHubリポジトリ](https://github.com/aoikonn129dhja/qwen_vast_sh)で **Actions → Build Salad images** を開く。
2. **Run workflow** を押し、Branchを **main** にして実行する。
3. 4つのbuildジョブがすべて緑のチェックになるまで待つ。
4. 各モデルのジョブを開き、**Run docker/build-push-action@v6** の左の矢印を押す。**Post Run** は開かない。
5. **Search logs** で `sha-` を検索し、`ghcr.io/` からコミットSHAの末尾までコピーして `salad_image_references.txt` に保存する。
6. GitHubプロフィールの **Packages** で対象packageを開く。Publicなら変更しない。Privateなら **Package settings → Danger Zone → Change visibility → Public** を選び、package名を入力して公開を確定する。
7. Saladの対象Groupの **Edit → Image Source** に新しいイメージ指定を入力する。

GPU・CPU・RAMの設定変更や、この手順書の更新だけならイメージの再ビルドは不要。

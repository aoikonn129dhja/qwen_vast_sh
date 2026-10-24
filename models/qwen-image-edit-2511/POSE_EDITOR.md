# 2511 骨格推定・編集ワークフロー

通常の2511セットアップ後に、任意の追加セットアップを実行します。

```bash
bash /workspace/qwen_vast_sh/models/qwen-image-edit-2511/setup_pose_editor.sh
```

2511専用ComfyUIをキューが空の状態で再起動し、ブラウザを再読み込みします。追加ノードは2511専用インスタンスへ導入され、他モデルの環境には導入されません。既存ワークフローは上書きしません。

`2511-pose-estimate-edit.json` をComfyUIで開きます。人物画像とポーズ参照画像を選び、次の順で使用します。配線変更は不要です。

1. 「1. 処理段階」を `estimate` にしてQueue。参照画像から骨格を推定し、骨格画像をプレビュー・保存します。2511の生成処理は遅延入力で除外します。
2. 「2. 骨格エディター」のプレビューまたは鉛筆をクリックし、関節をドラッグして `Apply`。
3. 「1. 処理段階」を `generate` にしてQueue。推定器を再実行せず、編集した骨格を2511の `image3` に渡します。
4. 編集した骨格ごとワークフローを保存します。参照画像を変更した場合は `estimate` に戻して再推定してください。

`image1` は人物・顔・衣装、`image2` はカメラ・場面、`image3` は編集した骨格です。画像3を参照画像として渡す構成で、専用ControlNetによる拘束ではありません。アニメ画像の推定精度や、骨格への生成結果の追従は実画像で確認が必要です。体と手指は編集できますが、顔の詳細点はエディターでの個別編集に対応していません。

初期値はLightning 4stepsと0.60MPです。推定画像と生成画像は既存のファイル名保持保存ノードへ送られます。最初のQueueではDWPoseの重みをダウンロードする場合があります。セットアップ自体は推定・画像生成を実行しません。

## 追加ノード

- [comfyui_controlnet_aux](https://github.com/Fannovel16/comfyui_controlnet_aux) の `DWPreprocessor`
- [OpenPose Studio](https://github.com/andreszs/comfyui-openpose-studio) の `OpenPoseStudio`
- 同梱 `ComfyUI-QwenPoseStages` の `QwenPoseStage` と `QwenPoseResult`

OpenPose Studioは `pose_keypoint` 入力がある場合、編集済みの `pose_json` より推定結果を優先します。同梱の段階切替ノードは `generate` 時にこの入力へ `None` を渡し、編集結果の上書きを防ぎます。結果切替ノードも遅延入力を使い、`estimate` 時に生成側へ進まないようにします。

ローカル回帰試験:

```bash
python -m unittest discover -s models/qwen-image-edit-2511/tests -v
```

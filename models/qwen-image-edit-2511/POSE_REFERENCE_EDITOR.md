# 2511 ポーズ編集：写真を背景へ自動表示

`setup_pose_editor.sh` を実行すると、既存の OpenPose Studio を基にした `OpenPose Studio Reference` と、`2511-pose-reference-edit.json` が追加されます。既存の `2511-pose-estimate-edit.json` は変更しません。

このワークフローでは、ポーズ元画像を縮小した後、同じ画像を DWPose の推定入力とエディターの `reference_image` に接続しています。画像はエディターの背景表示にだけ使い、Qwen の画像入力には接続しません。Qwen の `image1` は人物画像、`image2` は編集済み骨格画像で、`image3` は未接続です。生成解像度の元画像も人物画像です。

1. `reference_scale` を設定します。初期値 `0.8` は写真と推定骨格をキャンバス中央で 80% に縮小します。四辺に各 10% の余白ができます。
2. 段階を `estimate` にして Queue します。DWPose が関節を推定し、背景画像が自動的に準備されます。
3. `OpenPose Studio Reference` のプレビューをクリックします。縮小された写真の上で関節を調整し、`Apply` を押します。
4. 段階を `generate` にして Queue します。編集済み骨格が Qwen に渡されます。

縮小率を変更した場合は `estimate` を再実行してから編集してください。`generate` では保存済みの関節座標を再縮小しません。背景写真は骨格の出力画像にも生成モデルにも含まれません。

セットアップコマンド:

```bash
bash /workspace/qwen_vast_sh/models/qwen-image-edit-2511/setup_pose_editor.sh
```

セットアップは OpenPose Studio の固定コミットに小さなパッチを適用します。固定コミットと異なる版や競合するローカル変更がある場合は中止します。新ノードを読み込むには 2511 用 ComfyUI バックエンドの再起動が必要です。

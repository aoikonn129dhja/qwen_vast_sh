# Qwen Image 2.1 INT8 Lightning ＋ VNCCS Pose Transfer

従来の**1画像入力・Lightning 4steps**は維持し、**既存の3Dマネキン画像から人物画像へポーズを転写する機能**を追加する。元のセットアップのモデルファイル、共有ランタイム、Gateway、隔離されたPython環境を引き続き利用する。

## セットアップ

```bash
bash /workspace/qwen_vast_sh/models/qwen-image-2.1-int8-lightning/setup.sh
```

既存のINT8ベース、エンコーダ、VAE、Lightning LoRAを取得・再利用する。追加でVNCCS PoseStudio V1.1 LoRA（約159MB）、ポーズ転写用APIワークフロー、GUI用のVNCCS Utils・rgthreeノードを導入する。ノードは固定コミットで導入し、既存のPyTorch系パッケージの版を保持する。

## ComfyUI画面で使う

[同梱のGUIワークフロー](workflows/Qwen-Image-2.1-VNCCS-PoseStudio-GUI.json)をComfyUIで読み込む。[作者の配布版](https://huggingface.co/MIUProject/VNCCS_PoseStudio_QI2.1/blob/main/VNCCS_PoseStudio_QI2.1.json)のLoRA名を導入済みV1.1に合わせたもの。

- LoRAノードは導入済みの `VNCCS_QI2_PoseStudioV1.1.safetensors` を使用する。
- Load Imageで人物画像を選択する。
- VNCCS Pose Studioでポーズを編集し、実行する。
- この構成ではノードを直接導入するので、ComfyUI Managerは不要。

以前のセットアップにGUIノードだけを追加する場合は次を実行する。その後、実行中のキューがないことを確認してQwen Image 2.1のバックエンドを再起動する必要がある。

```bash
bash /workspace/qwen_vast_sh/models/qwen-image-2.1-int8-lightning/setup_vnccs_gui.sh
```

## 実行（Vast.ai / SaladCloud内）

```bash
python /workspace/qwen_vast_sh/models/qwen-image-2.1-int8-lightning/scripts/run_pose_transfer.py \
  --char /workspace/ComfyUI/input/character.png \
  --pose-ref /workspace/ComfyUI/input/mannequin.png \
  --out /workspace/ComfyUI/output/pose_result.png
```

- `--char`：保持したい人物の画像。
- `--pose-ref`：無地の3Dマネキンの姿勢画像。写真やイラストからの骨格抽出は不要。
- Image 1＝マネキン、Image 2＝人物。順序を入れ替えない。
- VNCCS LoRA強度1.0、25 steps、CFG 1.0、Euler/simple。Lightning LoRAはこの経路では適用しない。
- `--seed`、`--steps`、`--cfg`、`--lora-strength`で個別調整可能。
- 内部ComfyUIにアクセスできない場合のみ`--url http://127.0.0.1:8188`を環境に合わせて指定。

このCLIのワークフローは**ComfyUI API形式**。GUIのワークフロー読み込み用ではない。既存LightningのGUIワークフローは引き続き使用できる。

## 注意

- VNCCS専用LoRAが学習したマネキンの表現と異なる場合、姿勢転写に失敗する可能性がある。
- 現在のセットアップにはVNCCS LoRAの既知のSHA256値を登録していない。HTTPSで取得しファイルの最低サイズは確認するが、バイト単位の完全性保証はしない。必要ならハッシュを別途固定する。
- クラウド実GPUでの動作、画質、商用利用条件は未検証。元のリポジトリのライセンスとモデルウェイトの利用条件を確認する。
- セットアップはモデル別ランタイムを使う。別モデルとの切替でメモリ不足なら既存`runtime_control.py unload`を使用。

## 出典

- [Qwen 2.1 pose-transfer skill](https://github.com/Arekejoker/qwen21-nsfw-pose-skill)。参考にしたのはRoute③の入力順序と25step設定。スクリプトは本パッチで独立実装。
- [VNCCS PoseStudio LoRA](https://huggingface.co/MIUProject/VNCCS_PoseStudio_QI2.1)
- [ベースモデル](https://huggingface.co/Comfy-Org/Qwen-Image-2.1)

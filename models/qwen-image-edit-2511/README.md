# Qwen Image Edit 2511

ComfyUIの公式系Qwen Image Edit 2511 FP8 mixedと、DWPose/AnimePoseを準備します。

```bash
bash /workspace/qwen_vast_sh/models/qwen-image-edit-2511/setup.sh
```

このモデルにはリポジトリ管理のバッチworkflowがないため、セットアップ後はComfyUIから操作します。

公式workflowは `workflows/official.json` に同梱しています。出典はComfy-Org `workflow_templates` のコミット `0e5c5efb32ba6f3365d6da07da64aaf668157042` です。setup時に、公式workflowのBF16モデル名だけを同梱のFP8 mixedモデル名へ置換してComfyUIへ配置します。

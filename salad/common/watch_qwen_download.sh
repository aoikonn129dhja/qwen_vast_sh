#!/usr/bin/env bash
python3 - <<'PY'
import os
import time

path = "/opt/ComfyUI/models/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors.part"
total = 20533762817
previous_size = None
previous_time = None
smoothed_speed = None

print("Qwen Image Edit 2511 ダウンロード監視")
print("Ctrl+C で監視終了。ダウンロードは継続します。")

try:
    while True:
        now = time.monotonic()

        if not os.path.exists(path):
            print("ダウンロード中ファイルがありません。完了または中断の可能性があります。")
            break

        size = os.path.getsize(path)
        progress = min(size / total * 100, 100)
        remaining = max(total - size, 0)

        if previous_size is not None:
            elapsed = now - previous_time
            speed = max(0, (size - previous_size) / elapsed) if elapsed > 0 else 0

            if smoothed_speed is None:
                smoothed_speed = speed
            else:
                smoothed_speed = 0.3 * speed + 0.7 * smoothed_speed

        if smoothed_speed is not None and smoothed_speed > 0:
            eta = int(remaining / smoothed_speed)
            eta_text = f"{eta // 3600}時間{eta % 3600 // 60}分{eta % 60}秒"
            speed_text = f"{smoothed_speed / 1048576:.2f} MiB/秒"
        else:
            eta_text = "計算中"
            speed_text = "計算中"

        os.system("clear")
        print("=== Qwen Image Edit 2511 ダウンロード状況 ===")
        print(f"進捗率       ：{progress:.2f}%")
        print(f"取得済み     ：{size / 1e9:.2f} GB")
        print(f"合計容量     ：{total / 1e9:.2f} GB")
        print(f"残り容量     ：{remaining / 1e9:.2f} GB")
        print(f"ダウンロード速度：{speed_text}")
        print(f"推定残り時間 ：{eta_text}")
        print()
        print("※ モデル本体1ファイルの進捗です。")
        print("※ ComfyUIの起動時間や他のモデルの取得時間は含みません。")
        print("※ 推定時間は直近の転送速度に基づく概算です。")
        print("Ctrl+C：監視を終了")

        previous_size = size
        previous_time = now
        time.sleep(5)

except KeyboardInterrupt:
    print("\n監視を終了しました。ダウンロードは継続します。")
PY

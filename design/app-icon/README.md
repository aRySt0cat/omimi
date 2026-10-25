# Omimi のアプリアイコン

`codex` (画像生成) で作った 3 案。採用は **a**。

| 案 | 内容 |
|---|---|
| a (採用) | 筆の耳 + 24 時間の文字盤。浅葱の弧 = 録音した時間、山吹の点 = 印 |
| b | 線の太さが一定の耳 |
| c | 途切れた文字盤の中に耳 |

差し替えるときは 1024×1024・透明なしにして `ios/Omimi/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` を置き換える。

```bash
sips -s format jpeg mimi24_b.png --out /tmp/b.jpg && sips -z 1024 1024 -s format png /tmp/b.jpg --out ../../ios/Omimi/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

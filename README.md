# 動画生成アプリ（Flutter / Android）

Colab上のComfyUI（MiniMax H3）に つないで動画をつくるアプリです。

## 1. 作る手順（PCで1回だけ）
1. Flutter をインストールして `flutter doctor` が通る状態にする
2. このフォルダの中で次を実行（android フォルダなどを自動で足します）
   `flutter create --org com.example --project-name colab_video_app .`
3. `android/app/src/main/AndroidManifest.xml` の `<manifest>` の直下に追加
   `<uses-permission android:name="android.permission.INTERNET"/>`
4. `android/app/build.gradle(.kts)` の minSdk を 21 以上にする
5. `flutter pub get` → スマホをつないで `flutter run`（または `flutter build apk`）

## 2. Googleドライブ連携（任意。使わなくても手入力で動きます）
- Google Cloud Console で OAuth クライアント（Android）を作る
  （パッケージ名 `com.example.colab_video_app` と、デバッグ用SHA-1を登録）
- 同意画面にドライブの「読み取り専用」を足し、自分のアカウントをテストユーザーに入れる
- 設定しない場合は、接続タブの「URLとトークンを直接入力する」を使う

## 3. 使い方
1. Colabでノートブック `colab_video_app_server.ipynb` を「すべてのセルを実行」
2. アプリの接続タブで「Driveから接続情報を読む」→「接続テスト」
3. 生成タブで文字／画像／参照画像を選んで生成。動画は端末の中だけに保存されます

## 4. 注意
- ComfyUIのURLには認証がありません。URLを他人に教えないでください
- Colabを止めると接続タブが「停止中」になります（再接続ボタンで読み直し）
- 進捗のパーセント表示は、更新版ノートブック（client_id対応）で動きます

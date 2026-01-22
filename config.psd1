# WSL バックアップ設定ファイル
# このファイルを編集してバックアップ設定をカスタマイズしてください
@{
    # WSLディストリビューション名（wsl -l -v で確認可能）
    WslDistro = 'Ubuntu'

    # バックアップソース（複数指定可能）
    # 単一ディレクトリの場合: Sources = @('/home/aoki/projects')
    # 複数ディレクトリの場合: Sources = @('/home/aoki/projects', '/home/aoki/.config')
    Sources = @(
        '/home/aoki/projects'
    )

    # Windows側のバックアップ先ルートディレクトリ
    DestRoot = 'C:\Users\aoki\Dropbox\Projects_wsl'

    # アーカイブを保持する日数（0 = すべて保持）
    KeepDays = 15

    # ログファイルを保持する日数（0 = すべて保持）
    LogKeepDays = 30

    # 管理者権限が必要な場合、自動的に昇格するか
    # $true = UACダイアログを表示して昇格
    # $false = 昇格しない、エラーで終了
    AutoElevate = $true

    # robocopyのスレッド数（0 = 自動、CPUコア数に基づいて決定）
    ThreadCount = 0

    # バックアップ完了時にWindows通知を表示するか
    ShowNotification = $true

    # アーカイブ作成後に整合性検証を行うか
    VerifyArchive = $true

    # 必要な空きディスク容量（GB）（0 = チェックしない）
    RequiredFreeSpaceGB = 10
}

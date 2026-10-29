using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace DroidFrame;

sealed class MainForm : Form
{
    readonly Preferences preferences=Preferences.Load();
    readonly Compressor compressor=new();
    readonly FlowLayoutPanel sidebar=new() { Dock=DockStyle.Fill, FlowDirection=FlowDirection.TopDown, WrapContents=false, AutoScroll=true, Padding=new Padding(20) };
    readonly Panel right=new() { Dock=DockStyle.Fill, BackColor=Color.FromArgb(18,18,18) };
    readonly Panel surface=new() { BackColor=Color.Black, TabStop=true };
    readonly Label stage=new() { Dock=DockStyle.Fill, TextAlign=ContentAlignment.MiddleCenter, Text="Подключаем телефон…" };
    readonly Label status=TextLabel("Подключи телефон и разреши отладку по USB.");
    readonly Label clock=TextLabel("00:00");
    readonly Label folder=TextLabel("");
    readonly ComboBox devices=Choice([]), quality=Choice(["720p · экономно","1080p · чётче","Исходное разрешение"]), audio=Choice(["Звук телефона","Микрофон","Без звука"]), compression=Choice(["Без доп. сжатия","Компактное видео"]);
    readonly CheckBox removeOriginal=new() { Text="Удалять исходник после проверки", AutoSize=true, Margin=new Padding(0,4,0,10) };
    readonly Button record=Button("● Начать запись"), shot=Button("Скриншот"), choose=Button("Выбрать папку сохранения…"), open=Button("Открыть папку сохранения"), last=Button("Показать последний файл");
    readonly FlowLayoutPanel footer=new() { Dock=DockStyle.Bottom, FlowDirection=FlowDirection.TopDown, WrapContents=false, AutoSize=true, AutoSizeMode=AutoSizeMode.GrowAndShrink, Padding=new Padding(20,8,20,12), BackColor=Color.FromArgb(42,42,42), Visible=false };
    readonly Button dismiss=new() { Text="×", Width=24, Height=24, FlatStyle=FlatStyle.Flat, TabStop=true, AccessibleName="Скрыть панель сжатия" };
    readonly ProgressBar progress=new() { Width=290, Height=8, Maximum=100, Style=ProgressBarStyle.Continuous };
    readonly FlowLayoutPanel resultRows=new() { FlowDirection=FlowDirection.TopDown, WrapContents=false, AutoSize=true, AutoSizeMode=AutoSizeMode.GrowAndShrink, Width=290, Margin=Padding.Empty };
    readonly System.Windows.Forms.Timer timer=new() { Interval=200 };
    Process? backend;
    nint child;
    string? serial, lastFile, recordingFile;
    DateTime? started;
    DateTime lastScan=DateTime.MinValue;
    bool recording, switching, scanning, selecting, shuttingDown, closed, compressThisRecording, deleteThisRecording;
    double aspect=0.45;
    string backendLog="";

    public MainForm()
    {
        Text="DroidFrame"; ClientSize=new Size(720,790); MinimumSize=new Size(680,600); StartPosition=FormStartPosition.CenterScreen;
        BackColor=Color.FromArgb(30,30,30); ForeColor=Color.Gainsboro; Font=new Font("Segoe UI",10);
        Directory.CreateDirectory(Preferences.Home); File.WriteAllText(Path.Combine(Preferences.Home,"session.log"),"DroidFrame 1.6.0\n");
        var left=new Panel { Dock=DockStyle.Left, Width=350, BackColor=BackColor };
        left.Controls.Add(sidebar); left.Controls.Add(footer); Controls.Add(right); Controls.Add(left);
        right.Controls.Add(surface); right.Controls.Add(stage);
        var title=TextLabel("DROIDFRAME"); title.Font=new Font(Font.FontFamily,20,FontStyle.Bold);
        Add(title); Add(TextLabel("Экран телефона. Всё под рукой.")); Add(devices); status.Height=55; Add(status);
        clock.Font=new Font(Font.FontFamily,34); clock.Height=65; Add(clock); Add(TextLabel("Без ограничения длительности")); Add(record); Add(shot);
        Add(TextLabel("Качество")); Add(quality); Add(TextLabel("Сжатие")); Add(compression); Add(removeOriginal); Add(TextLabel("Аудио")); Add(audio);
        Add(choose); Add(open); Add(folder); Add(last); Add(TextLabel("Скриншоты доступны во время записи."));
        quality.SelectedIndex=Math.Clamp(preferences.Quality,0,2); audio.SelectedIndex=Math.Clamp(preferences.Audio,0,2); compression.SelectedIndex=preferences.Compress?1:0; removeOriginal.Checked=preferences.RemoveOriginal;
        var closeRow=new Panel { Width=290, Height=24, Margin=Padding.Empty }; dismiss.Dock=DockStyle.Right; closeRow.Controls.Add(dismiss); footer.Controls.Add(closeRow); footer.Controls.Add(resultRows); footer.Controls.Add(progress);
        dismiss.Click+=(_,_)=>footer.Visible=false;
        record.Click+=async (_,_)=>await Guard(ToggleRecording);
        shot.Click+=async (_,_)=>await Guard(Screenshot);
        choose.Click+=(_,_)=> { using var dialog=new FolderBrowserDialog { InitialDirectory=preferences.Folder, Description="Куда сохранять видео и скриншоты" }; if(dialog.ShowDialog(this)==DialogResult.OK) { preferences.Folder=dialog.SelectedPath; preferences.Save(); RefreshFolder(); } };
        open.Click+=(_,_)=> { try { Directory.CreateDirectory(preferences.Folder); Process.Start(new ProcessStartInfo(preferences.Folder) { UseShellExecute=true }); } catch(Exception e) { Fail(e); } };
        last.Click+=(_,_)=> { if(lastFile!=null && File.Exists(lastFile)) { var info=new ProcessStartInfo("explorer.exe") { UseShellExecute=true }; info.ArgumentList.Add("/select,"); info.ArgumentList.Add(lastFile); Process.Start(info); } };
        foreach(var choice in new[]{quality,audio,compression}) choice.SelectedIndexChanged+=(_,_)=>SaveOptions();
        removeOriginal.CheckedChanged+=(_,_)=>SaveOptions();
        devices.SelectedIndexChanged+=async (_,_)=> { if(selecting || switching || recording) return; if(devices.SelectedItem is Device d && d.Serial!=serial) await Guard(async()=> { await StopBackend(); serial=d.Serial; await StartBackend(false); }); };
        compressor.Progress+=(text,value)=>UI(()=> { footer.Visible=true; SetRows([(text,"")]); progress.Value=(int)value; });
        compressor.Completed+=result=>UI(()=> { lastFile=result.File; footer.Visible=true; progress.Value=result.Error==null?100:0; SetRows([(result.Error==null?"✓ Готово":result.Error,""),("Файл: ",Path.GetFileName(result.File)),("Папка: ",Path.GetDirectoryName(result.File)!),("Размер: ",Tools.Size(result.Bytes))]); });
        right.Resize+=(_,_)=>LayoutSurface();
        timer.Tick+=async (_,_)=> { if(started is { } at) clock.Text=(DateTime.UtcNow-at).ToString(@"hh\:mm\:ss"); if(!scanning && DateTime.UtcNow-lastScan>TimeSpan.FromSeconds(2)) await Guard(Scan); };
        Shown+=async (_,_)=> { RefreshFolder(); UpdateControls(); timer.Start(); await Guard(Scan); };
        FormClosing+=OnClosing;
        KeyPreview=true; KeyDown+=async (_,e)=> { if(e.Control && e.KeyCode==Keys.R) { e.SuppressKeyPress=true; if(record.Enabled) await Guard(ToggleRecording); } if(e.Control && e.Shift && e.KeyCode==Keys.S) { e.SuppressKeyPress=true; if(shot.Enabled) await Guard(Screenshot); } };
    }
    static Label TextLabel(string text)=>new() { Text=text, AutoSize=true, MaximumSize=new Size(290,0), Margin=new Padding(0,5,0,10) };
    static ComboBox Choice(string[] values) { var c=new ComboBox { Width=290, DropDownStyle=ComboBoxStyle.DropDownList, Margin=new Padding(0,0,0,10) }; c.Items.AddRange(values); if(values.Length>0)c.SelectedIndex=0;return c; }
    static Button Button(string text)=>new() { Text=text, Width=290, Height=34, Margin=new Padding(0,0,0,10), FlatStyle=FlatStyle.Flat, BackColor=Color.FromArgb(55,55,55), ForeColor=Color.Gainsboro, UseVisualStyleBackColor=false };
    void Add(Control control)=>sidebar.Controls.Add(control);
    void UI(Action action) { if(!closed && !IsDisposed) { if(InvokeRequired) BeginInvoke(action); else action(); } }
    async Task Guard(Func<Task> action) { try { await action(); } catch(Exception e) { Fail(e); } }
    void Fail(Exception e) { Tools.Log(e.ToString()); status.Text="Ошибка: "+e.Message; stage.Text="Не удалось подключиться.\nПроверь телефон и разрешение отладки."; stage.Visible=true; switching=false; UpdateControls(); }
    void RefreshFolder() { Directory.CreateDirectory(preferences.Folder); folder.Text="Сохранение: "+preferences.Folder; }
    void SaveOptions() { preferences.Quality=quality.SelectedIndex; preferences.Audio=audio.SelectedIndex; preferences.Compress=compression.SelectedIndex==1; preferences.RemoveOriginal=removeOriginal.Checked; preferences.Save(); removeOriginal.Visible=preferences.Compress; }
    void UpdateControls()
    {
        record.Text=recording?"■ Стоп и сохранить":"● Начать запись"; record.BackColor=recording?Color.FromArgb(115,45,45):Color.FromArgb(55,55,55);
        record.Enabled=serial!=null && !switching && !shuttingDown; shot.Enabled=serial!=null && !switching && !shuttingDown;
        devices.Enabled=!recording && !switching && !shuttingDown; quality.Enabled=audio.Enabled=compression.Enabled=removeOriginal.Enabled=!recording && !switching && !shuttingDown;
        choose.Enabled=!switching && !shuttingDown; removeOriginal.Visible=compression.SelectedIndex==1; last.Enabled=lastFile!=null;
    }
    void SetRows((string Prefix,string Value)[] rows)
    {
        resultRows.SuspendLayout(); foreach(Control c in resultRows.Controls.Cast<Control>().ToArray()) c.Dispose(); resultRows.Controls.Clear();
        for(int i=0;i<rows.Length;i++)
        {
            if(i>0) resultRows.Controls.Add(new Panel { Width=290, Height=1, BackColor=Color.FromArgb(85,85,85), Margin=new Padding(0,5,0,5) });
            var row=rows[i]; string text=row.Prefix+row.Value;
            var field=new RichTextBox { Text=text, Width=290, ReadOnly=true, BorderStyle=BorderStyle.None, BackColor=footer.BackColor, ForeColor=ForeColor, Font=new Font(Font.FontFamily,9), ScrollBars=RichTextBoxScrollBars.None, WordWrap=true, DetectUrls=false, TabStop=false, Margin=new Padding(0,4,0,4) };
            field.Select(0,row.Prefix.Length); field.SelectionFont=new Font(field.Font,FontStyle.Bold); field.Select(0,0);
            resultRows.Controls.Add(field);
            // RichEdit measures exactly the text it draws, including long paths.
            field.Height=Math.Max(24,field.GetPositionFromCharIndex(Math.Max(0,text.Length-1)).Y+field.Font.Height+8);
        }
        resultRows.ResumeLayout(true); footer.PerformLayout(); UpdateControls();
    }
    async Task Scan()
    {
        if(switching || shuttingDown) return;
        scanning=true; lastScan=DateTime.UtcNow;
        try
        {
            var all=Device.Parse(await Tools.AdbText("devices","-l")); var ready=all.Where(d=>d.State=="device").ToList();
            if(!devices.Items.Cast<Device>().Select(d=>d.Serial).SequenceEqual(ready.Select(d=>d.Serial)))
            {
                selecting=true; devices.Items.Clear(); foreach(var device in ready)devices.Items.Add(device); devices.SelectedItem=ready.FirstOrDefault(d=>d.Serial==serial) ?? ready.FirstOrDefault(); selecting=false;
            }
            if(recording) { if(backend is { HasExited:true }) await StopBackend(); else return; }
            if(backend!=null && backend.HasExited) { backend.Dispose(); backend=null; child=0; }
            if(backend==null && ready.Count>0) { serial=(devices.SelectedItem as Device ?? ready[0]).Serial; await StartBackend(false); }
            if(ready.Count==0)
            {
                serial=null; status.Text=all.Any(d=>d.State=="unauthorized")?"Разблокируй телефон и подтверди разрешение отладки.":all.Any(d=>d.State=="offline")?"Телефон offline. Переподключи кабель.":"Подключи телефон и включи отладку по USB.";
                stage.Text=status.Text; stage.Visible=true;
            }
            UpdateControls();
        }
        finally { scanning=false; selecting=false; }
    }
    void LayoutSurface()
    {
        int height=Math.Max(1,Math.Min(right.Height,(int)(right.Width/aspect))); int width=Math.Max(1,(int)(height*aspect));
        surface.SetBounds((right.Width-width)/2,(right.Height-height)/2,width,height);
        if(child!=0) Native.MoveWindow(child,0,0,width,height,true);
    }
    void ReadBackendLine(string? line)
    {
        if(line==null)return;
        Tools.Log(line); backendLog=line;
        var size=Regex.Match(line,@"Texture: (\d+)x(\d+)");
        if(size.Success && int.TryParse(size.Groups[1].Value,out int width) && int.TryParse(size.Groups[2].Value,out int height) && width>0 && height>0)
            UI(()=> { aspect=(double)width/height; LayoutSurface(); });
    }
    async Task StartBackend(bool capture)
    {
        if(serial==null) return;
        switching=true; stage.Visible=true; stage.BringToFront(); stage.Text=capture?"Подготавливаем запись…":"Подключаем экран телефона…"; status.Text=stage.Text; UpdateControls();
        Process? process=null;
        try
        {
            string sdkText=await Tools.AdbText("-s",serial,"shell","getprop","ro.build.version.sdk"); int.TryParse(sdkText.Trim(),out int sdk);
            string dimensions=await Tools.AdbText("-s",serial,"shell","wm","size"); var matches=Regex.Matches(dimensions,@"(\d+)x(\d+)"); if(matches.Count>0) { var m=matches[^1]; aspect=double.Parse(m.Groups[1].Value)/double.Parse(m.Groups[2].Value); }
            var args=new List<string> { "--serial",serial,"--window-title=DroidFrameSurface-"+Guid.NewGuid(),"--window-borderless","--window-x=-32000","--window-y=-32000","--window-height=740","--video-codec=h264","--max-fps=30","--video-bit-rate=8M","--stay-awake","--max-size="+new[]{"1600","2400","0"}[quality.SelectedIndex] };
            if(capture)
            {
                Directory.CreateDirectory(preferences.Folder); recordingFile=Tools.FreePath(preferences.Folder,"DroidFrame-"+DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss-fff"),".mp4"); args.Add("--record="+recordingFile);
                args.Add("--audio-codec=aac");
                if(audio.SelectedIndex==2 || sdk<30) args.Add("--no-audio");
                else if(audio.SelectedIndex==1) args.AddRange(["--audio-source=mic","--no-audio-playback"]);
                else if(sdk>=33) args.AddRange(["--audio-source=playback","--audio-dup","--no-audio-playback"]);
                else args.Add("--audio-source=output");
                compressThisRecording=preferences.Compress; deleteThisRecording=preferences.RemoveOriginal;
            }
            else args.Add("--no-audio");
            process=new Process { StartInfo=Tools.StartInfo(Tools.Scrcpy,args),EnableRaisingEvents=true }; backendLog="";
            process.OutputDataReceived+=(_,e)=>ReadBackendLine(e.Data);
            process.ErrorDataReceived+=(_,e)=>ReadBackendLine(e.Data);
            process.Start(); backend=process; process.BeginOutputReadLine(); process.BeginErrorReadLine();
            for(int i=0;i<200;i++) { if(process.HasExited)throw new IOException("scrcpy: "+backendLog); child=Native.Find(process.Id); if(child!=0)break; await Task.Delay(100); }
            if(child==0) throw new IOException("Телефон не передал изображение за 20 секунд.");
            Native.Embed(child,surface.Handle); LayoutSurface(); Native.ShowWindow(child,5);
            recording=capture; started=capture?DateTime.UtcNow:null; switching=false; stage.Visible=false;
            status.Text=capture?"● Идёт запись. Для сохранения нажми «Стоп».":"Телефон подключён. Можно записывать видео и делать скриншоты.";
            UpdateControls();
        }
        catch { if(process!=null && !process.HasExited)process.Kill(true); process?.Dispose(); backend=null; child=0; switching=false; throw; }
    }
    async Task StopBackend()
    {
        Process? process=backend; if(process==null)return;
        switching=true; stage.Visible=true; stage.BringToFront(); stage.Text=recording?"Сохраняем запись…":"Подготавливаем экран…"; status.Text=stage.Text; UpdateControls();
        bool wasRecording=recording; double elapsed=started is { } start?(DateTime.UtcNow-start).TotalSeconds:0;
        bool clean=true;
        try
        {
            if(!process.HasExited)
            {
                if(child!=0) Native.PostMessage(child,0x0010,0,0); else process.CloseMainWindow();
                using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(20));
                try { await process.WaitForExitAsync(timeout.Token); }
                catch(OperationCanceledException) { clean=false; process.Kill(true); await process.WaitForExitAsync(); }
            }
            clean &= process.ExitCode==0;
        }
        finally { process.Dispose(); backend=null; child=0; recording=false; started=null; }
        if(wasRecording && recordingFile is { } file && File.Exists(file))
        {
            lastFile=file;
            if(clean)
            {
                try { await Task.Run(()=>Mp4Duration.Pad(file,elapsed)); } catch(Exception e) { Tools.Log("Duration: "+e.Message); }
                if(compressThisRecording) _=compressor.Enqueue(file,deleteThisRecording);
            }
            else { status.Text="Запись прервалась. Исходный файл сохранён для проверки."; Tools.Log("Recording did not exit cleanly; original retained, compression skipped."); }
        }
        switching=false; UpdateControls();
    }
    async Task ToggleRecording() { if(switching || shuttingDown)return; bool next=!recording; await StopBackend(); await StartBackend(next); }
    async Task Screenshot()
    {
        if(serial==null || switching)return; shot.Enabled=false;
        try
        {
            string id=serial; var bytes=(await Tools.Run(Tools.Adb,["-s",id,"exec-out","screencap","-p"])).Bytes;
            if(bytes.Length<24 || !bytes.AsSpan(0,8).SequenceEqual(new byte[]{137,80,78,71,13,10,26,10}))throw new IOException("Телефон не вернул PNG.");
            Directory.CreateDirectory(preferences.Folder); string file=Tools.FreePath(preferences.Folder,"Screenshot-"+DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss-fff"),".png");
            await File.WriteAllBytesAsync(file,bytes); lastFile=file; status.Text="Скриншот сохранён: "+Path.GetFileName(file);
        }
        finally { UpdateControls(); }
    }
    async void OnClosing(object? sender,FormClosingEventArgs e)
    {
        if(closed)return; e.Cancel=true; if(shuttingDown)return;
        shuttingDown=true; timer.Stop(); UpdateControls();
        // Do not kill a recording or encoder during shutdown.
        while(switching || scanning) await Task.Delay(100);
        try { await StopBackend(); stage.Visible=true; stage.Text="Завершаем сохранение и сжатие…"; await compressor.Drain(); preferences.Save(); }
        catch(Exception error) { Tools.Log(error.ToString()); }
        closed=true; Close();
    }
}

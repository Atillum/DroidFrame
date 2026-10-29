using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace DroidFrame;

record Device(string Serial, string State, string Name)
{
    public override string ToString() => Name;
    public static List<Device> Parse(string output)
    {
        var devices = new List<Device>();
        foreach (string line in output.Split('\n'))
        {
            var match = Regex.Match(line.Trim(), @"^(.*?)\s+(device|offline|unauthorized)(?:\s|$)(.*)$");
            if (!match.Success) continue;
            string serial = match.Groups[1].Value;
            var model = Regex.Match(match.Groups[3].Value,@"(?:^|\s)model:(\S+)");
            devices.Add(new(serial,match.Groups[2].Value,model.Success ? model.Groups[1].Value.Replace('_',' ') : serial));
        }
        return devices;
    }
}

sealed class Preferences
{
    public string Folder { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),"DroidFrame");
    public int Quality { get; set; } = 1;
    public int Audio { get; set; }
    public bool Compress { get; set; }
    public bool RemoveOriginal { get; set; }
    public static string Home => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"DroidFrame");
    public static Preferences Load()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(Home,"settings.json"))) ?? new(); }
        catch { return new(); }
    }
    public void Save()
    {
        Directory.CreateDirectory(Home);
        var target = Path.Combine(Home,"settings.json");
        File.WriteAllText(target+".tmp",JsonSerializer.Serialize(this));
        File.Move(target+".tmp",target,true);
    }
}

static class Tools
{
    public static string Scrcpy => Path.Combine(AppContext.BaseDirectory,"deps","scrcpy","scrcpy.exe");
    public static string Adb => Path.Combine(AppContext.BaseDirectory,"deps","scrcpy","adb.exe");
    public static string Ffmpeg => Path.Combine(AppContext.BaseDirectory,"deps","ffmpeg","ffmpeg.exe");
    public static string Ffprobe => Path.Combine(AppContext.BaseDirectory,"deps","ffmpeg","ffprobe.exe");
    public static ProcessStartInfo StartInfo(string executable, IEnumerable<string> args)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true, WorkingDirectory=Path.GetDirectoryName(executable)! };
        foreach (string arg in args) info.ArgumentList.Add(arg);
        info.Environment["ADB"] = Adb;
        info.Environment["SCRCPY_SERVER_PATH"] = Path.Combine(Path.GetDirectoryName(Scrcpy)!,"scrcpy-server");
        return info;
    }
    public static async Task<(byte[] Bytes,string Error)> Run(string executable, IEnumerable<string> args, int seconds=30)
    {
        using var process = new Process { StartInfo=StartInfo(executable,args) };
        process.Start();
        using var memory = new MemoryStream();
        var copy = process.StandardOutput.BaseStream.CopyToAsync(memory);
        var error = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch { if (!process.HasExited) process.Kill(true); await process.WaitForExitAsync(); throw new IOException("Операция заняла слишком много времени. Проверь подключение телефона."); }
        await copy; string detail = await error;
        if (process.ExitCode != 0) throw new IOException(string.IsNullOrWhiteSpace(detail) ? "Внешняя программа завершилась с ошибкой." : detail);
        return (memory.ToArray(),detail);
    }
    public static async Task<string> AdbText(params string[] args) => System.Text.Encoding.UTF8.GetString((await Run(Adb,args)).Bytes);
    public static void Log(string text)
    {
        try { Directory.CreateDirectory(Preferences.Home); File.AppendAllText(Path.Combine(Preferences.Home,"session.log"),DateTime.Now.ToString("s")+" "+text+Environment.NewLine); } catch { }
    }
    public static string FreePath(string folder,string basename,string extension)
    {
        string path = Path.Combine(folder,basename+extension); int index=2;
        while(File.Exists(path)) path=Path.Combine(folder,basename+"-"+(index++)+extension);
        return path;
    }
    public static string Size(long bytes) => bytes >= 1048576 ? $"{bytes/1048576.0:F1} МБ" : $"{bytes/1024.0:F0} КБ";
    public static string Seconds(double value) => value.ToString("0.000",CultureInfo.InvariantCulture);
}

record MediaInfo(double Duration,int Width,int Height,bool Audio);
record CompressionResult(string File,long Bytes,string? Error,bool Smaller);

sealed class Compressor
{
    readonly SemaphoreSlim queue = new(1,1);
    int pending;
    public bool IsBusy => Volatile.Read(ref pending)>0;
    public event Action<string,double>? Progress;
    public event Action<CompressionResult>? Completed;
    public static async Task<MediaInfo> Probe(string path)
    {
        var bytes = (await Tools.Run(Tools.Ffprobe,["-v","error","-show_streams","-show_format","-of","json",path])).Bytes;
        using var document=JsonDocument.Parse(bytes); var root=document.RootElement;
        var video=root.GetProperty("streams").EnumerateArray().First(s=>s.GetProperty("codec_type").GetString()=="video");
        double duration=double.Parse(root.GetProperty("format").GetProperty("duration").GetString()!,CultureInfo.InvariantCulture);
        return new(duration,video.GetProperty("width").GetInt32(),video.GetProperty("height").GetInt32(),root.GetProperty("streams").EnumerateArray().Any(s=>s.GetProperty("codec_type").GetString()=="audio"));
    }
    public async Task<CompressionResult> Enqueue(string source,bool removeOriginal)
    {
        Interlocked.Increment(ref pending);
        await queue.WaitAsync();
        string temporary=Path.Combine(Path.GetDirectoryName(source)!,".compression-"+Guid.NewGuid()+".mp4");
        CompressionResult result;
        try
        {
            Progress?.Invoke("Подготовка сжатия…",0);
            MediaInfo input=await Probe(source); long before=new FileInfo(source).Length;
            using var process=new Process { StartInfo=Tools.StartInfo(Tools.Ffmpeg,["-hide_banner","-nostdin","-y","-loglevel","error","-i",source,"-map","0:v:0","-map","0:a:0?","-c:v","libx264","-crf","28","-preset","fast","-pix_fmt","yuv420p","-vf","fps=30,tpad=stop_mode=clone:stop_duration="+Tools.Seconds(input.Duration),"-t",Tools.Seconds(input.Duration),"-c:a","aac","-b:a","96k","-movflags","+faststart","-progress","pipe:1","-nostats",temporary]) };
            process.Start(); var errors=process.StandardError.ReadToEndAsync();
            while(await process.StandardOutput.ReadLineAsync() is { } line)
                if(line.StartsWith("out_time_us=") && double.TryParse(line[12..],NumberStyles.Float,CultureInfo.InvariantCulture,out double value))
                { double percent=Math.Clamp(value/1000000/Math.Max(input.Duration,0.001)*100,0,99); Progress?.Invoke($"Сжатие: {percent:F0}%",percent); }
            await process.WaitForExitAsync();
            string error=await errors;
            if(process.ExitCode!=0) throw new IOException(error);
            MediaInfo output=await Probe(temporary);
            if(output.Width!=input.Width || output.Height!=input.Height || output.Audio!=input.Audio || Math.Abs(output.Duration-input.Duration)>Math.Max(0.5,input.Duration*0.01)) throw new IOException("Проверка сжатого файла не пройдена.");
            long after=new FileInfo(temporary).Length;
            if(after<1024) throw new IOException("Сжатый файл слишком мал.");
            if(after>=before) { File.Delete(temporary); result=new(source,before,null,false); }
            else
            {
                string destination=Tools.FreePath(Path.GetDirectoryName(source)!,Path.GetFileNameWithoutExtension(source)+"_compressed",".mp4");
                File.Move(temporary,destination);
                // Original removal is opt-in and happens only after validation and successful move.
                if(removeOriginal) { try { File.Delete(source); } catch(Exception e) { Tools.Log("Original preserved: "+e.Message); } }
                result=new(destination,after,null,true);
            }
        }
        catch(Exception e) { Tools.Log("Compression: "+e); result=new(source,File.Exists(source)?new FileInfo(source).Length:0,"Сжатие не удалось — исходник сохранён",false); }
        finally { try { File.Delete(temporary); } catch { } }
        try { Completed?.Invoke(result); }
        finally { Interlocked.Decrement(ref pending); queue.Release(); }
        return result;
    }
    public async Task Drain() { while(IsBusy) await Task.Delay(100); }
}

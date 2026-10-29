using System.Text.Json;

namespace DroidFrame;

static class SelfTest
{
    static void Check(bool condition,string message) { if(!condition)throw new Exception(message); }
    public static async Task Run()
    {
        var devices=Device.Parse("List of devices attached\nusb123 device product:a model:Pixel_9 transport_id:1\nadb-ab cd (2)._adb-tls-connect._tcp device model:SM_S928B\nblocked unauthorized\noff offline\n");
        Check(devices.Count==4 && devices[0].Name=="Pixel 9" && devices[1].Serial=="adb-ab cd (2)._adb-tls-connect._tcp" && devices[2].State=="unauthorized","Device parser");
        using(var host=new Form())
        using(var child=new Form { Text="DroidFrameSurface-test" })
        {
            host.Show();child.Show();Application.DoEvents();Native.Embed(child.Handle,host.Handle);Native.MoveWindow(child.Handle,0,0,200,400,true);
            Check(Native.GetParent(child.Handle)==host.Handle,"Native window embedding");child.Close();host.Close();
        }
        using(var form=new MainForm()) { Check(form.Text=="DroidFrame","UI construction"); }
        await Tools.Run(Tools.Adb,["version"]);await Tools.Run(Tools.Scrcpy,["--version"]);
        string folder=Path.Combine(Path.GetTempPath(),"DroidFrame test с пробелами "+Guid.NewGuid());Directory.CreateDirectory(folder);
        try
        {
            string input=Path.Combine(folder,"Видео.mp4");
            await Tools.Run(Tools.Ffmpeg,["-hide_banner","-loglevel","error","-f","lavfi","-i","testsrc2=size=360x800:rate=30","-f","lavfi","-i","sine=frequency=440:sample_rate=48000","-t","2","-c:v","libx264","-crf","8","-c:a","aac",input],60);
            var before=await Compressor.Probe(input);Check(before.Width==360 && before.Height==800 && before.Audio,"Generated fixture");
            byte[] original=File.ReadAllBytes(input);Mp4Duration.Pad(input,6);
            var padded=await Compressor.Probe(input);Check(Math.Abs(padded.Duration-6)<0.1,"Static-screen duration");
            int mdat=FindType(original,"mdat");int moov=FindType(original,"moov");byte[] changed=File.ReadAllBytes(input);
            Check(mdat>0 && moov>mdat && original.AsSpan(0,moov-4).SequenceEqual(changed.AsSpan(0,moov-4)),"Encoded media untouched");
            var compressor=new Compressor();double maximum=0;compressor.Progress+=(_,v)=>maximum=Math.Max(maximum,v);
            var result=await compressor.Enqueue(input,false);Check(result.Error==null && result.Smaller && File.Exists(input) && File.Exists(result.File),"Compression and original preservation");
            var encoded=await Compressor.Probe(result.File);Check(Math.Abs(encoded.Duration-6)<0.15 && encoded.Audio,"Compressed duration and audio");
            await Tools.Run(Tools.Ffmpeg,["-v","error","-i",result.File,"-f","null","-"],60);
            var collision=await compressor.Enqueue(input,false);Check(collision.Error==null && collision.File!=result.File && File.Exists(result.File),"No overwrite on collision");
            string removable=Path.Combine(folder,"remove.mp4");File.Copy(input,removable);var removed=await compressor.Enqueue(removable,true);Check(removed.Error==null && removed.Smaller && !File.Exists(removable),"Opt-in original removal");
            string invalid=Path.Combine(folder,"invalid.mp4");File.WriteAllText(invalid,"not a video");var failed=await compressor.Enqueue(invalid,true);Check(failed.Error!=null && File.Exists(invalid),"Original retained on failure");
            Check(!compressor.IsBusy,"Queue drained");
            File.WriteAllText(Path.Combine(AppContext.BaseDirectory,"self-test-report.json"),JsonSerializer.Serialize(new { passed=true,deviceParser=true,embeddedWindow=true,compression=true,staticDuration=true,originalProtection=true,unicodePaths=true,maximumProgress=maximum }));
        }
        finally { Directory.Delete(folder,true); }
    }
    static int FindType(byte[] bytes,string type)
    {
        byte[] pattern=System.Text.Encoding.ASCII.GetBytes(type);for(int i=4;i<bytes.Length-4;i++)if(bytes.AsSpan(i,4).SequenceEqual(pattern))return i;return -1;
    }
}

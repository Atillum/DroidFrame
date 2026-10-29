namespace DroidFrame;

internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Contains("--self-test"))
        {
            try { SelfTest.Run().GetAwaiter().GetResult(); return 0; }
            catch (Exception e) { File.WriteAllText(Path.Combine(AppContext.BaseDirectory,"self-test-error.txt"),e.ToString()); return 1; }
        }
        Application.ThreadException += (_, e) => MessageBox.Show(e.Exception.Message,"DroidFrame");
        Application.Run(new MainForm());
        return 0;
    }
}

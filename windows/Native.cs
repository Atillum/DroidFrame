using System.Runtime.InteropServices;
using System.Text;

namespace DroidFrame;

static class Native
{
    delegate bool EnumProc(nint window,nint parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,nint data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(nint window,out uint process);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(nint window,StringBuilder text,int max);
    [DllImport("user32.dll",SetLastError=true)] static extern nint SetParent(nint child,nint parent);
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] static extern nint GetStyle(nint window,int index);
    [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")] static extern nint SetStyle(nint window,int index,nint style);
    [DllImport("user32.dll")] public static extern bool MoveWindow(nint window,int x,int y,int width,int height,bool repaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(nint window,int command);
    [DllImport("user32.dll")] public static extern bool PostMessage(nint window,uint message,nint w,nint l);
    [DllImport("user32.dll")] public static extern nint GetParent(nint window);
    public static nint Find(int process)
    {
        nint result=0;
        EnumWindows((window,_)=> { GetWindowThreadProcessId(window,out uint pid); if(pid!=(uint)process) return true; var text=new StringBuilder(256); GetWindowText(window,text,256); if(text.ToString().StartsWith("DroidFrameSurface-")){result=window;return false;} return true; },0);
        return result;
    }
    public static void Embed(nint window,nint parent)
    {
        ShowWindow(window,0);
        long style=GetStyle(window,-16).ToInt64();
        style &= ~(0x80000000L | 0x00C00000L | 0x00040000L | 0x00800000L | 0x00400000L);
        style |= 0x40000000L; // WS_CHILD; keep visibility off until positioned.
        SetStyle(window,-16,(nint)style);
        SetParent(window,parent);
        if(GetParent(window)!=parent) throw new IOException("Не удалось встроить экран телефона в окно.");
    }
}

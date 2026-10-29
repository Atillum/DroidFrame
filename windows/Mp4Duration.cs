using System.Buffers.Binary;
using System.Text;

namespace DroidFrame;

// Extend the final static-screen sample without re-encoding or changing mdat.
// Only scrcpy's small trailing metadata is rewritten, with rollback on failure.
static class Mp4Duration
{
    sealed record Atom(string Type,byte[] Body)
    {
        public byte[] Encode() { byte[] data=new byte[Body.Length+8]; Put(data,0,4,(ulong)data.Length); Encoding.ASCII.GetBytes(Type).CopyTo(data,4); Body.CopyTo(data,8); return data; }
    }
    static ulong Read(byte[] data,int offset,int count)
    {
        if(offset<0 || offset+count>data.Length)throw new InvalidDataException("Invalid MP4 atom");
        ulong value=0; for(int i=0;i<count;i++)value=(value<<8)|data[offset+i]; return value;
    }
    static void Put(byte[] data,int offset,int count,ulong value)
    {
        if(offset<0 || offset+count>data.Length || (count==4 && value>uint.MaxValue))throw new InvalidDataException("MP4 timing overflow");
        for(int i=count-1;i>=0;i--) { data[offset+i]=(byte)value;value>>=8; }
    }
    static List<Atom> Parse(byte[] data)
    {
        var atoms=new List<Atom>(); int offset=0;
        while(offset<data.Length) { int size=checked((int)Read(data,offset,4)); if(size<8 || size>data.Length-offset)throw new InvalidDataException("Invalid MP4 size"); atoms.Add(new(Encoding.ASCII.GetString(data,offset+4,4),data[(offset+8)..(offset+size)])); offset+=size; } return atoms;
    }
    static byte[] Join(IEnumerable<Atom> atoms) { using var stream=new MemoryStream();foreach(var atom in atoms)stream.Write(atom.Encode());return stream.ToArray(); }
    static (ulong Scale,ulong Duration,int Offset,int Count) Timing(byte[] data)
    {
        bool v1=Read(data,0,1)==1; int offset=v1?24:16,count=v1?8:4; return(Read(data,v1?20:12,4),Read(data,offset,count),offset,count);
    }
    static Atom Extend(Atom atom,ulong scale,ulong target)
    {
        var track=Parse(atom.Body); int mdia=track.FindIndex(a=>a.Type=="mdia"),tkhd=track.FindIndex(a=>a.Type=="tkhd"); if(mdia<0 || tkhd<0)return atom;
        var media=Parse(track[mdia].Body); var handler=media.FirstOrDefault(a=>a.Type=="hdlr");
        if(handler==null || handler.Body.Length<12 || Encoding.ASCII.GetString(handler.Body,8,4)!="vide")return atom;
        int mdhd=media.FindIndex(a=>a.Type=="mdhd"),minf=media.FindIndex(a=>a.Type=="minf"); if(mdhd<0 || minf<0)return atom;
        bool v1=Read(track[tkhd].Body,0,1)==1;int headerOffset=v1?28:20,headerCount=v1?8:4;
        ulong old=Read(track[tkhd].Body,headerOffset,headerCount);if(target<=old)return atom;
        ulong delta=target-old;var timing=Timing(media[mdhd].Body);if(scale==0 || timing.Scale==0)throw new InvalidDataException();
        ulong mediaDelta=(ulong)Math.Round(delta*(double)timing.Scale/scale);
        var info=Parse(media[minf].Body);int stbl=info.FindIndex(a=>a.Type=="stbl");if(stbl<0)throw new InvalidDataException();
        var table=Parse(info[stbl].Body);int sttsIndex=table.FindIndex(a=>a.Type=="stts");if(sttsIndex<0)throw new InvalidDataException();
        byte[] stts=table[sttsIndex].Body;int entries=checked((int)Read(stts,4,4));if(entries<=0 || stts.Length!=8+entries*8)throw new InvalidDataException();
        int last=8+(entries-1)*8;ulong count=Read(stts,last,4),duration=Read(stts,last+4,4);if(count==0 || duration+mediaDelta>uint.MaxValue)throw new InvalidDataException();
        if(count==1)Put(stts,last+4,4,duration+mediaDelta);
        else { Put(stts,last,4,count-1);Put(stts,4,4,(ulong)entries+1);Array.Resize(ref stts,stts.Length+8);Put(stts,stts.Length-8,4,1);Put(stts,stts.Length-4,4,duration+mediaDelta); }
        table[sttsIndex]=new("stts",stts);info[stbl]=new("stbl",Join(table));media[minf]=new("minf",Join(info));
        Put(media[mdhd].Body,timing.Offset,timing.Count,timing.Duration+mediaDelta);track[mdia]=new("mdia",Join(media));Put(track[tkhd].Body,headerOffset,headerCount,target);
        int edts=track.FindIndex(a=>a.Type=="edts");
        if(edts>=0) { var edits=Parse(track[edts].Body);var elst=edits.FirstOrDefault(a=>a.Type=="elst");if(elst!=null) { bool editV1=Read(elst.Body,0,1)==1;int n=checked((int)Read(elst.Body,4,4));if(n<1)throw new InvalidDataException();int offset=8+(n-1)*(editV1?20:12),bytes=editV1?8:4;Put(elst.Body,offset,bytes,Read(elst.Body,offset,bytes)+delta);track[edts]=new("edts",Join(edits)); } }
        return new(atom.Type,Join(track));
    }
    public static void Pad(string path,double elapsed)
    {
        if(elapsed<1)return;
        using var file=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.Read);long total=file.Length,offset=0,moov=-1,mediaEnd=0;byte[] header=new byte[16];
        while(offset+8<=total)
        {
            file.Position=offset;int n=file.Read(header);if(n<8)throw new InvalidDataException();ulong length=Read(header,0,4);string type=Encoding.ASCII.GetString(header,4,4);
            if(length==1)length=Read(header,8,8);if(length==0)length=(ulong)(total-offset);if(length<8 || length>(ulong)(total-offset))throw new InvalidDataException();
            if(type=="moov")moov=offset;if(type=="mdat")mediaEnd=offset+(long)length;offset+=(long)length;
        }
        if(moov<0 || mediaEnd>moov || total-moov>64*1024*1024)throw new InvalidDataException("Unsupported MP4 layout; original retained");
        file.Position=moov;byte[] original=new byte[checked((int)(total-moov))];file.ReadExactly(original);
        var root=Parse(original);int index=root.FindIndex(a=>a.Type=="moov");var movie=Parse(root[index].Body);int mvhd=movie.FindIndex(a=>a.Type=="mvhd");var timing=Timing(movie[mvhd].Body);
        if(timing.Scale==0)throw new InvalidDataException();ulong target=(ulong)Math.Round(elapsed*timing.Scale);if((double)target-timing.Duration<timing.Scale*0.8)return;
        for(int i=0;i<movie.Count;i++)if(movie[i].Type=="trak")movie[i]=Extend(movie[i],timing.Scale,target);
        Put(movie[mvhd].Body,timing.Offset,timing.Count,target);root[index]=new("moov",Join(movie));byte[] updated=Join(root);
        try { file.Position=moov;file.Write(updated);file.SetLength(moov+updated.Length);file.Flush(true); }
        catch { file.Position=moov;file.Write(original);file.SetLength(total);file.Flush(true);throw; }
    }
}

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

// Built twice: by the .NET Framework compiler against the real
// JavaScriptSerializer and by the .NET SDK against JsonCompat.cs. Each writes
// what it read and wrote for the same inputs; test.ps1 requires the two to
// be the same, byte for byte.
internal static class JsonCompatTests
{
    public sealed class Receipt
    {
        public Receipt() { Version = 1; }
        public int Version { get; set; }
        public Guid Owner { get; set; }
        public string[] Addresses { get; set; }
        public Guid[] Filters { get; set; }
    }

    private static readonly string[] Inputs = {
        "{}", "[]", "1", "\"text\"", "true", "null", " { \"a\" : 1 } ",
        "{\"small\":2147483647,\"large\":2147483648,\"negative\":-2147483649,\"huge\":99999999999999999999,\"zero\":-0}",
        "{\"fraction\":1.5,\"exponent\":1e3,\"padded\":0.10,\"tiny\":1E-30}",
        "{\"escapes\":\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0001\\u00e9\\u2028\"}",
        "{\"text\":\"привет <b> & 'x'\"}",
        "{\"same\":1,\"same\":2}",
        "{\"list\":[1,\"two\",[3],{\"four\":4},null,false]}",
        "{\"a\":{\"b\":{\"c\":1}}}", "{\"a\":{\"b\":{}}}", "[[[]]]", "[[[1]]]",
        // What both refuse, or read as nothing.
        "", " ", "{", "{\"a\":}", "[1,]", "{\"a\":1,}", "\"\\x41\"",
    };

    // Not JSON, which .NET Framework still reads. Current .NET refuses it, as
    // the router and the macOS client do.
    private static readonly string[] NotJson = {
        "{'a':1}", "{a:1}", "\"\\ud800\"", "01", "+1", ".5", "NaN", "{\"a\":1} x", "\"line\nbreak\"", "\"\t\"",
    };

    private static string Describe(object value)
    {
        if (value == null) return "null";
        if (value is string) return "s:" + Escape((string)value);
        if (value is bool) return (bool)value ? "true" : "false";
        if (value is int) return "i:" + ((int)value).ToString(CultureInfo.InvariantCulture);
        if (value is long) return "l:" + ((long)value).ToString(CultureInfo.InvariantCulture);
        if (value is decimal) return "m:" + ((decimal)value).ToString(CultureInfo.InvariantCulture);
        if (value is double) return "d:" + ((double)value).ToString("r", CultureInfo.InvariantCulture);
        var fields = value as Dictionary<string, object>;
        if (fields != null) return "{" + String.Join(",", fields.Select(p => Escape(p.Key) + "=" + Describe(p.Value)).ToArray()) + "}";
        var items = value as object[];
        if (items != null) return "[" + String.Join(",", items.Select(Describe).ToArray()) + "]";
        var list = value as System.Collections.ArrayList;
        if (list != null) return "L[" + String.Join(",", list.Cast<object>().Select(Describe).ToArray()) + "]";
        return "?" + value.GetType().Name;
    }

    private static string Escape(string text)
    {
        var result = new StringBuilder();
        foreach (char c in text) result.Append(c < ' ' || c > '~' ? "\\u" + ((int)c).ToString("x4", CultureInfo.InvariantCulture) : c.ToString());
        return result.ToString();
    }

    private static string Failure(Exception error)
    {
        return error is ArgumentException ? "! argument" : error is InvalidOperationException ? "! operation" : "! " + error.GetType().Name;
    }

    private static string Read(string input, int limit, int depth)
    {
        try { return Describe(new JavaScriptSerializer { MaxJsonLength = limit, RecursionLimit = depth }.DeserializeObject(input)); }
        catch (Exception error) { return Failure(error); }
    }

    private static string Write(object value, int limit)
    {
        try { return Escape(new JavaScriptSerializer { MaxJsonLength = limit }.Serialize(value)); }
        catch (Exception error) { return Failure(error); }
    }

    private static int Main(string[] args)
    {
        var lines = new List<string>();
        for (int i = 0; i < Inputs.Length; i++)
        {
            lines.Add("read " + i + " " + Read(Inputs[i], 2097152, 100));
            for (int depth = 1; depth <= 4; depth++) lines.Add("depth " + i + " " + depth + " " + Read(Inputs[i], 2097152, depth));
            lines.Add("short " + i + " " + Read(Inputs[i], 4, 100));
            try { lines.Add("again " + i + " " + Write(new JavaScriptSerializer().DeserializeObject(Inputs[i]), 2097152)); }
            catch (Exception error) { lines.Add("again " + i + " " + Failure(error)); }
        }
#if NET
        for (int i = 0; i < NotJson.Length; i++)
            if (Read(NotJson[i], 2097152, 100) != "! argument") { Console.Error.WriteLine("FAIL not JSON is read: " + Escape(NotJson[i])); return 1; }
#endif
        try { lines.Add("null " + Describe(new JavaScriptSerializer().DeserializeObject(null))); }
        catch (Exception error) { lines.Add("null " + Failure(error)); }

        var owner = new Guid("0f8fad5b-d9cb-469f-a165-70867728950e");
        var receipt = new Receipt { Owner = owner, Addresses = new[] { "198.51.100.0/24", "203.0.113.7" }, Filters = new[] { owner, Guid.Empty } };
        string stored = new JavaScriptSerializer().Serialize(receipt);
        lines.Add("receipt " + Escape(stored));
        var back = new JavaScriptSerializer().Deserialize<Receipt>(stored);
        lines.Add("receipt back " + back.Version + " " + back.Owner + " " + String.Join(" ", back.Addresses) + " " + String.Join(" ", back.Filters.Select(g => g.ToString()).ToArray()));
        var loose = new JavaScriptSerializer().Deserialize<Receipt>("{\"version\":2,\"OWNER\":\"" + owner + "\",\"addresses\":[],\"unknown\":1}");
        lines.Add("receipt loose " + loose.Version + " " + loose.Owner + " " + loose.Addresses.Length + " " + (loose.Filters == null));
        lines.Add("map " + Describe(new JavaScriptSerializer().Deserialize<Dictionary<string, object>>("{\"a\":[1,{\"b\":[2]}],\"c\":{\"d\":[]}}")));

        lines.Add("write " + Write(new Dictionary<string, object> {
            { "text", "\"\\/\b\f\n\r\t\u0001\u001f <>&' é \u2028 \ud83d\ude00" }, { "int", 7 }, { "long", 1234567890123L }, { "negative", -5 },
            { "decimal", 1.50m }, { "double", 0.1 }, { "whole", 2.0 }, { "true", true }, { "none", null }, { "guid", owner },
            { "ints", new[] { 1, 2 } }, { "strings", new List<string> { "a", "b" } }, { "nested", new Dictionary<string, object> { { "x", new object[] { } } } },
            { "uint", 4000000000u }, { "ulong", 18446744073709551615ul }, { "byte", (byte)255 },
        }, 2097152));
        lines.Add("write anonymous " + Write(new { Version = 3, State = "connected", Services = new[] { "a" }, Missing = (string)null }, 2097152));
        lines.Add("write short " + Write(new Dictionary<string, object> { { "text", "longer than the limit" } }, 8));
        lines.Add("write top " + Write("<top>", 2097152) + " " + Write(42, 2097152) + " " + Write(null, 2097152));

        // Every shared policy and history, as the clients read and write them again.
        for (int file = 0; file < args.Length - 1; file++)
        {
            var cases = new JavaScriptSerializer { MaxJsonLength = 8388608 }.DeserializeObject(File.ReadAllText(args[file])) as object[];
            for (int i = 0; i < cases.Length; i++)
            {
                foreach (var field in (Dictionary<string, object>)cases[i])
                {
                    string text = field.Value as string;
                    if (text == null) text = new JavaScriptSerializer { MaxJsonLength = 8388608 }.Serialize(field.Value);
                    lines.Add("fixture " + file + " " + i + " " + field.Key + " " + Read(text, 1048576, 12));
                    lines.Add("fixture again " + file + " " + i + " " + field.Key + " " + Write(field.Value, 8388608));
                }
            }
        }
        File.WriteAllLines(args[args.Length - 1], lines.ToArray(), new UTF8Encoding(false));
        return 0;
    }
}

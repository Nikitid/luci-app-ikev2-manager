#if NET
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;

namespace System.Web.Script.Serialization
{
    // The JavaScriptSerializer of .NET Framework, as far as these clients use
    // it, for the builds on current .NET where it does not exist. It writes
    // the same text and reads into the same types: what a service of an
    // earlier release stored is read unchanged, the canonical text of a
    // policy stays byte for byte the same, and bad input fails with the same
    // exceptions. JsonCompatTests compares the two on the same inputs.
    internal sealed class JavaScriptSerializer
    {
        public int MaxJsonLength { get; set; } = 2097152;
        public int RecursionLimit { get; set; } = 100;

        public object DeserializeObject(string input)
        {
            if (input == null) throw new ArgumentNullException(nameof(input));
            if (input.Length > MaxJsonLength) throw new ArgumentException("Input exceeds the maximum length");
            // Nothing at all reads as null there, not as an error.
            if (input.Trim().Length == 0) return null;
            try
            {
                using (var document = JsonDocument.Parse(input, new JsonDocumentOptions { MaxDepth = RecursionLimit + 1 }))
                    return Read(document.RootElement, 1);
            }
            catch (JsonException error) { throw new ArgumentException("Invalid JSON primitive", error); }
            catch (InvalidOperationException error) { throw new ArgumentException("Invalid JSON string", error); }
        }

        // Every value counts one level deeper than the one holding it, as the
        // .NET Framework reader counts them.
        private object Read(JsonElement element, int depth)
        {
            if (depth > RecursionLimit) throw new ArgumentException("Recursion limit exceeded");
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    var fields = new Dictionary<string, object>();
                    foreach (var property in element.EnumerateObject()) fields[property.Name] = Read(property.Value, depth + 1);
                    return fields;
                case JsonValueKind.Array:
                    var items = new List<object>();
                    foreach (var item in element.EnumerateArray()) items.Add(Read(item, depth + 1));
                    return items.ToArray();
                case JsonValueKind.String: return element.GetString();
                case JsonValueKind.True: return true;
                case JsonValueKind.False: return false;
                case JsonValueKind.Null: return null;
                default: return Number(element.GetRawText());
            }
        }

        private static object Number(string text)
        {
            // With an exponent a double; with a point only a decimal; whole
            // numbers the smallest of int, long and decimal that holds them.
            if (text.IndexOfAny(new[] { 'e', 'E' }) >= 0) return Double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
            if (text.IndexOf('.') < 0)
            {
                if (Int32.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out int small)) return small;
                if (Int64.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out long large)) return large;
            }
            if (Decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal exact)) return exact;
            return Double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
        }

        public T Deserialize<T>(string input) { return (T)Convert(DeserializeObject(input), typeof(T)); }

        // Read for a dictionary or an object rather than through
        // DeserializeObject, lists there are ArrayLists, at every level.
        private static object Lists(object value)
        {
            if (value is object[] items) { var list = new ArrayList(); foreach (object item in items) list.Add(Lists(item)); return list; }
            if (value is Dictionary<string, object> fields) { foreach (string key in new List<string>(fields.Keys)) fields[key] = Lists(fields[key]); }
            return value;
        }

        // Into a dictionary, or an object whose properties are named by the
        // fields in any case, as the .NET Framework serializer fills them.
        private static object Convert(object value, Type type)
        {
            if (value == null) return type.IsValueType ? Activator.CreateInstance(type) : null;
            if (type == typeof(object) || type == typeof(Dictionary<string, object>)) return Lists(value);
            if (type.IsInstanceOfType(value)) return value;
            if (type == typeof(Guid) && value is string guid) return Guid.Parse(guid);
            if (type.IsArray && value is object[] list)
            {
                var result = Array.CreateInstance(type.GetElementType(), list.Length);
                for (int i = 0; i < list.Length; i++) result.SetValue(Convert(list[i], type.GetElementType()), i);
                return result;
            }
            if (value is object[] entries && type.IsGenericType && type.GetGenericTypeDefinition() == typeof(List<>))
            {
                var result = (IList)Activator.CreateInstance(type);
                foreach (object entry in entries) result.Add(Convert(entry, type.GetGenericArguments()[0]));
                return result;
            }
            if (type.IsPrimitive || type == typeof(decimal)) return System.Convert.ChangeType(value, type, CultureInfo.InvariantCulture);
            if (value is Dictionary<string, object> fields && type.GetConstructor(Type.EmptyTypes) != null)
            {
                object target = Activator.CreateInstance(type);
                foreach (var field in fields)
                {
                    var property = type.GetProperty(field.Key, BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase);
                    if (property == null || !property.CanWrite) continue;
                    property.SetValue(target, Convert(field.Value, property.PropertyType));
                }
                return target;
            }
            throw new InvalidOperationException("Cannot convert to " + type.Name);
        }

        public string Serialize(object value)
        {
            var text = new StringBuilder();
            Write(text, value);
            if (text.Length > MaxJsonLength) throw new InvalidOperationException("Output exceeds the maximum length");
            return text.ToString();
        }

        private static void Write(StringBuilder text, object value)
        {
            switch (value)
            {
                case null: text.Append("null"); return;
                case string s: Quote(text, s); return;
                case char c: Quote(text, c.ToString()); return;
                case bool b: text.Append(b ? "true" : "false"); return;
                case Guid g: Quote(text, g.ToString()); return;
                case Enum e: text.Append(System.Convert.ToInt64(e, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)); return;
                case double d: text.Append(d.ToString("r", CultureInfo.InvariantCulture)); return;
                case float f: text.Append(f.ToString("r", CultureInfo.InvariantCulture)); return;
                case IFormattable n when value.GetType().IsPrimitive || value is decimal: text.Append(n.ToString(null, CultureInfo.InvariantCulture)); return;
                case IDictionary map:
                    text.Append('{');
                    bool firstKey = true;
                    foreach (DictionaryEntry entry in map)
                    {
                        if (!firstKey) text.Append(',');
                        firstKey = false;
                        Quote(text, entry.Key.ToString());
                        text.Append(':');
                        Write(text, entry.Value);
                    }
                    text.Append('}');
                    return;
                case IEnumerable list:
                    text.Append('[');
                    bool firstItem = true;
                    foreach (object item in list)
                    {
                        if (!firstItem) text.Append(',');
                        firstItem = false;
                        Write(text, item);
                    }
                    text.Append(']');
                    return;
            }
            // Public fields first, then readable properties, in declaration order.
            text.Append('{');
            bool first = true;
            Type type = value.GetType();
            foreach (var field in type.GetFields(BindingFlags.Public | BindingFlags.Instance))
            {
                if (!first) text.Append(',');
                first = false;
                Quote(text, field.Name); text.Append(':'); Write(text, field.GetValue(value));
            }
            foreach (var property in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (!property.CanRead || property.GetIndexParameters().Length != 0) continue;
                if (!first) text.Append(',');
                first = false;
                Quote(text, property.Name); text.Append(':'); Write(text, property.GetValue(value));
            }
            text.Append('}');
        }

        private static void Quote(StringBuilder text, string value)
        {
            text.Append('"');
            foreach (char c in value)
            {
                switch (c)
                {
                    case '"': text.Append("\\\""); break;
                    case '\\': text.Append("\\\\"); break;
                    case '\b': text.Append("\\b"); break;
                    case '\f': text.Append("\\f"); break;
                    case '\n': text.Append("\\n"); break;
                    case '\r': text.Append("\\r"); break;
                    case '\t': text.Append("\\t"); break;
                    default:
                        if (c < ' ' || c == '<' || c == '>' || c == '\'' || c == '&')
                            text.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else text.Append(c);
                        break;
                }
            }
            text.Append('"');
        }
    }
}
#endif

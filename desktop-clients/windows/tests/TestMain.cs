using System;
using System.Linq;
using System.Reflection;

// Runs the Main of the test class named first, with the arguments after it,
// and returns what it returns. A failure that escapes it is printed and fails.
// Tests that start this program again for a helper process pass their own
// arguments only; the class they belong to comes to it in the environment.
internal static class TestMain
{
    private const string Inherited = "WAYPOINT_TEST_CLASS";

    private static int Main(string[] args)
    {
        string name = Environment.GetEnvironmentVariable(Inherited);
        if (name == null && args.Length > 0) { name = args[0]; args = args.Skip(1).ToArray(); }
        Type test = name == null ? null : typeof(TestMain).Assembly.GetType(name, false);
        MethodInfo main = test?.GetMethod("Main", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
        if (main == null) { Console.Error.WriteLine("usage: Waypoint.Tests <TestClass> [arguments]"); return 2; }
        Environment.SetEnvironmentVariable(Inherited, name);
        object[] call = main.GetParameters().Length == 0 ? new object[0] : new object[] { args };
        try
        {
            object result = main.Invoke(null, call);
            return result is int code ? code : 0;
        }
        catch (TargetInvocationException failure)
        {
            Console.Error.WriteLine(failure.InnerException);
            return 1;
        }
    }
}

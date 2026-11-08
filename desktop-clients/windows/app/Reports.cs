using IkeV2Manager.Client;

namespace Waypoint;

// The reports sent from this computer and what support said about them, as
// the window knows it: the journal on disk and the latest conversations. The
// service is asked off the window's thread; what it answers lands on it.
sealed class Reports
{
    readonly ReportJournal journal = new();
    readonly Dictionary<string, ReportConversation> conversations = new();
    bool looking;

    public List<SentReport> All { get; private set; }
    // Called on the window's thread whenever an answer of the service changed what is known.
    public event Action Changed;

    public Reports() { All = Load(); }

    // The person's own reports and those the service sent by itself after
    // the person agreed; the latter are kept by the service for the device.
    List<SentReport> Load()
    {
        var all = journal.Load();
        try
        {
            using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Waypoint\Reports");
            if (key?.GetValue("Reports") is string text &&
                new System.Web.Script.Serialization.JavaScriptSerializer().DeserializeObject(text) is object[] items)
                foreach (var item in items.OfType<Dictionary<string, object>>())
                {
                    if (item.GetValueOrDefault("id") is not string id || item.GetValueOrDefault("claim") is not string claim || all.Any(r => r.Id == id)) continue;
                    DateTime.TryParse(item.GetValueOrDefault("sent_at") as string, System.Globalization.CultureInfo.InvariantCulture,
                        System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var sent);
                    all.Add(new SentReport { Id = id, Claim = claim, Kind = "crash", Title = "Сбой Waypoint: " + (item.GetValueOrDefault("code") as string ?? ""), SentAt = sent });
                }
        }
        catch (Exception) { }
        return all.OrderByDescending(r => r.SentAt).ToList();
    }

    public ReportConversation Conversation(SentReport report) => conversations.TryGetValue(report.Id, out var known) ? known : null;
    public int UnreadOf(SentReport report) => Math.Max(0, (Conversation(report)?.FromSupport ?? 0) - report.Seen);
    // Support's replies the person has not opened yet.
    public int Unread => All.Sum(UnreadOf);

    public void Keep(SentReport sent)
    {
        try { journal.Add(sent); } catch (Exception) { }
        All = Load();
        Changed?.Invoke();
    }

    // The person opened REPORT: what support said so far is seen.
    public void MarkRead(SentReport report)
    {
        var conversation = Conversation(report);
        if (conversation == null || conversation.FromSupport == report.Seen) return;
        try { journal.MarkSeen(report.Id, conversation.FromSupport); } catch (Exception) { }
        report.Seen = conversation.FromSupport;
        All = Load();
        Changed?.Invoke();
    }

    // Asks the service about the twenty newest reports; one it no longer
    // knows leaves the journal. DONE runs on the window's thread after.
    public async void LookAround(Action done = null)
    {
        if (looking) return;
        looking = true;
        try
        {
            All = Load();
            foreach (var report in All.Take(20).ToList()) await LookAt(report);
            All = Load();
            Changed?.Invoke();
            done?.Invoke();
        }
        finally { looking = false; }
    }

    public async Task LookAt(SentReport report)
    {
        try
        {
            var conversation = await Task.Run(() => new ProblemReporter().Conversation(report));
            conversations[report.Id] = conversation;
        }
        catch (ProblemReportException gone) when (gone.Kind == "gone")
        {
            conversations.Remove(report.Id);
            try { journal.Remove(report.Id); } catch (Exception) { }
        }
        catch (Exception) { }
    }

    public static string Words(Exception error) => (error as ProblemReportException)?.Kind switch
    {
        "unavailable" => "Сервис отчётов сейчас не принимает отчёты Waypoint.",
        "busy" => "Сервис отчётов занят; отправьте снова через несколько минут.",
        "unreachable" => "Сервис отчётов недоступен. Проверьте интернет и отправьте снова.",
        "gone" => "Обращение больше не найдено на сервере.",
        "refused" => "Сервис отклонил отчёт: " + error.Message,
        _ => "Не отправлено.",
    };
}

using System;
using System.Reflection;
using System.Windows.Forms;

internal static class TrayRestoreLifecycleHarness
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 1) throw new ArgumentException("Provide the widget executable path.");

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        Assembly widgetAssembly = Assembly.LoadFrom(args[0]);
        Type formType = widgetAssembly.GetType("SwissArmyVpn.VpnForm", true);
        ConstructorInfo constructor = formType.GetConstructor(
            BindingFlags.Instance | BindingFlags.NonPublic,
            null,
            new[] { widgetAssembly.GetType("SwissArmyVpn.WidgetState", true) },
            null);
        MethodInfo restore = formType.GetMethod("RestoreFromTray", BindingFlags.Instance | BindingFlags.NonPublic);
        if (constructor == null || restore == null) throw new MissingMethodException("Tray lifecycle members were not found.");

        using (Form form = (Form)constructor.Invoke(new object[] { null }))
        {
            form.Show();
            Application.DoEvents();
            form.WindowState = FormWindowState.Minimized;
            Application.DoEvents();
            if (form.Visible) throw new InvalidOperationException("The minimized form did not hide to the tray.");

            restore.Invoke(form, null);
            Application.DoEvents();
            if (!form.Visible || form.WindowState != FormWindowState.Normal || form.Handle == IntPtr.Zero)
                throw new InvalidOperationException("The form did not restore to a visible normal window.");

        }

        Console.WriteLine("TRAY RESTORE LIFECYCLE: PASS");
        return 0;
    }
}

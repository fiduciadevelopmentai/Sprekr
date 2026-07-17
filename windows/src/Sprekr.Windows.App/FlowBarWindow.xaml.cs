using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Sprekr.Windows.Core;

namespace Sprekr.Windows.App;

public partial class FlowBarWindow : Window
{
    private const int GwlExstyle = -20;
    private const int WsExNoactivate = 0x08000000;
    private const int WsExToolwindow = 0x00000080;

    public FlowBarWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            SetWindowLongPtr(handle, GwlExstyle, new IntPtr(GetWindowLongPtr(handle, GwlExstyle).ToInt64() | WsExNoactivate | WsExToolwindow));
        };
        Loaded += (_, _) => PositionAtBottom();
    }

    public void UpdateState(FlowBarState state, string message)
    {
        StateDot.Fill = new SolidColorBrush(state switch
        {
            FlowBarState.Listening => System.Windows.Media.Color.FromRgb(235, 92, 92),
            FlowBarState.Processing => System.Windows.Media.Color.FromRgb(244, 183, 64),
            FlowBarState.Error => System.Windows.Media.Color.FromRgb(235, 92, 92),
            FlowBarState.Cancelled => System.Windows.Media.Color.FromRgb(160, 160, 170),
            _ => System.Windows.Media.Color.FromRgb(116, 87, 232)
        });
        StateText.Text = string.IsNullOrWhiteSpace(message) ? "Sprekr is gereed" : message;
        PositionAtBottom();
    }

    private void PositionAtBottom()
    {
        Left = SystemParameters.WorkArea.Left + (SystemParameters.WorkArea.Width - Width) / 2;
        Top = SystemParameters.WorkArea.Bottom - Height - 24;
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
}

public sealed class WpfFlowBarController(FlowBarWindow window, Func<bool> isEnabled) : IFlowBarController
{
    public void SetState(FlowBarState state, string message = "") => window.Dispatcher.BeginInvoke(() =>
    {
        if (!isEnabled() || state == FlowBarState.Hidden) { window.Hide(); return; }
        window.UpdateState(state, message);
        if (!window.IsVisible) window.Show();
    });
}

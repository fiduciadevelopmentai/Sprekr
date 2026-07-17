namespace Sprekr.Windows.Core;

public enum DictationState { Idle, Recording, Processing, CancelledUndoWindow }
public enum DictationAction { None, Start, StopAndProcess, Cancel, UndoCancel }

public sealed class DictationStateMachine
{
    private readonly object gate = new();

    public DictationState State { get; private set; } = DictationState.Idle;

    public DictationAction Press(DictationMode mode)
    {
        lock (gate)
        {
            if (State == DictationState.Idle)
            {
                State = DictationState.Recording;
                return DictationAction.Start;
            }

            if (mode == DictationMode.Toggle && State == DictationState.Recording)
            {
                State = DictationState.Processing;
                return DictationAction.StopAndProcess;
            }

            return DictationAction.None;
        }
    }

    public DictationAction Release(DictationMode mode)
    {
        lock (gate)
        {
            if (mode == DictationMode.Hold && State == DictationState.Recording)
            {
                State = DictationState.Processing;
                return DictationAction.StopAndProcess;
            }
            return DictationAction.None;
        }
    }

    public DictationAction Escape()
    {
        lock (gate)
        {
            if (State != DictationState.Recording) return DictationAction.None;
            State = DictationState.CancelledUndoWindow;
            return DictationAction.Cancel;
        }
    }

    public DictationAction Undo()
    {
        lock (gate)
        {
            if (State != DictationState.CancelledUndoWindow) return DictationAction.None;
            State = DictationState.Processing;
            return DictationAction.UndoCancel;
        }
    }

    public void Complete()
    {
        lock (gate) State = DictationState.Idle;
    }

    public void ResetAfterSystemChange()
    {
        lock (gate)
        {
            if (State != DictationState.Processing) State = DictationState.Idle;
        }
    }
}

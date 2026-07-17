using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Sprekr.Windows.Infrastructure;

internal static class Dpapi
{
    private const uint CryptprotectUiForbidden = 0x1;

    public static byte[] Protect(byte[] plaintext) => Transform(plaintext, protect: true);
    public static byte[] Unprotect(byte[] ciphertext) => Transform(ciphertext, protect: false);

    private static byte[] Transform(byte[] input, bool protect)
    {
        var inputPointer = Marshal.AllocHGlobal(input.Length);
        try
        {
            Marshal.Copy(input, 0, inputPointer, input.Length);
            var inputBlob = new DataBlob { Size = input.Length, Data = inputPointer };
            DataBlob outputBlob;
            var success = protect
                ? CryptProtectData(ref inputBlob, "Sprekr local encryption key", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    CryptprotectUiForbidden, out outputBlob)
                : CryptUnprotectData(ref inputBlob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    CryptprotectUiForbidden, out outputBlob);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows DPAPI kon de lokale sleutel niet verwerken.");
            try
            {
                var output = new byte[outputBlob.Size];
                Marshal.Copy(outputBlob.Data, output, 0, output.Length);
                return output;
            }
            finally
            {
                LocalFree(outputBlob.Data);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(inputPointer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn, string description, IntPtr optionalEntropy, IntPtr reserved,
        IntPtr promptStruct, uint flags, out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn, IntPtr description, IntPtr optionalEntropy, IntPtr reserved,
        IntPtr promptStruct, uint flags, out DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}

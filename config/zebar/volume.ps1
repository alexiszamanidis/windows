# Reads and changes the default playback volume.
# Zebar 3.3.1's audio provider crashes the bar when Windows reports that there
# is no default device, so this script talks to the endpoint directly and
# never registers a device-change notification.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

trap {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace BarVolume {
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr pNotify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr pNotify);
        [PreserveSig] int GetChannelCount(out uint pnChannelCount);
        [PreserveSig] int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float pfLevelDB);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float pfLevel);
        [PreserveSig] int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    public static class Control {
        const int Render = 0;
        const int Multimedia = 1;
        const int ClsCtxAll = 23;
        static readonly object Gate = new object();
        static string last = "";

        static IAudioEndpointVolume Endpoint() {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            int hr = enumerator.GetDefaultAudioEndpoint(Render, Multimedia, out device);
            if (hr != 0 || device == null) {
                return null;
            }

            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object activated;
            hr = device.Activate(ref iid, ClsCtxAll, IntPtr.Zero, out activated);
            if (hr != 0 || activated == null) {
                return null;
            }

            return activated as IAudioEndpointVolume;
        }

        public static string Read() {
            try {
                IAudioEndpointVolume endpoint = Endpoint();
                if (endpoint == null) {
                    return "none";
                }

                float level;
                bool muted;
                if (endpoint.GetMasterVolumeLevelScalar(out level) != 0) {
                    return "none";
                }
                if (endpoint.GetMute(out muted) != 0) {
                    return "none";
                }

                int percent = (int)Math.Round(level * 100f);
                if (percent < 0) {
                    percent = 0;
                }
                if (percent > 100) {
                    percent = 100;
                }
                return percent.ToString() + (muted ? " 1" : " 0");
            } catch {
                return "none";
            }
        }

        public static void SetVolume(int percent) {
            try {
                IAudioEndpointVolume endpoint = Endpoint();
                if (endpoint == null) {
                    return;
                }
                if (percent < 0) {
                    percent = 0;
                }
                if (percent > 100) {
                    percent = 100;
                }
                Guid context = Guid.Empty;
                endpoint.SetMasterVolumeLevelScalar(percent / 100f, ref context);
            } catch {
            }
        }

        public static void SetMute(bool mute) {
            try {
                IAudioEndpointVolume endpoint = Endpoint();
                if (endpoint == null) {
                    return;
                }
                Guid context = Guid.Empty;
                endpoint.SetMute(mute, ref context);
            } catch {
            }
        }

        public static void Publish(bool force) {
            lock (Gate) {
                string line = Read();
                if (!force && line == last) {
                    return;
                }
                last = line;
                Console.Out.WriteLine(line);
                Console.Out.Flush();
            }
        }

        static void ReadCommands() {
            string line;
            while ((line = Console.In.ReadLine()) != null) {
                string[] parts = line.Trim().Split(new[] { ' ' }, 2);
                if (parts.Length == 2 && parts[0] == "v") {
                    int percent;
                    if (int.TryParse(parts[1], out percent)) {
                        SetVolume(percent);
                    }
                } else if (parts.Length == 2 && parts[0] == "m") {
                    SetMute(parts[1] == "1");
                }
                Publish(true);
            }
            Environment.Exit(0);
        }

        public static void Run() {
            Console.OutputEncoding = new System.Text.UTF8Encoding(false);
            Thread input = new Thread(ReadCommands);
            input.IsBackground = true;
            input.Start();
            while (true) {
                Publish(false);
                Thread.Sleep(400);
            }
        }
    }
}
'@

[BarVolume.Control]::Run()

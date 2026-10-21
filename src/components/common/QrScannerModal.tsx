import React, { useEffect, useRef, useState } from 'react';
import { BrowserQRCodeReader } from '@zxing/browser';
import { useApp } from '../../context/AppContext';
import { ActivityModel } from '../../types';
import { QrCode, CheckCircle2, AlertCircle, X, Camera, Sparkles } from 'lucide-react';

interface QrScannerModalProps {
  activity?: ActivityModel;
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
}

export const QrScannerModal: React.FC<QrScannerModalProps> = ({
  activity,
  isOpen,
  onClose,
  onSuccess,
}) => {
  const { activities, users, verifyAttendanceByQr, canQuickSwitchRole } = useApp();
  const [selectedActivityId, setSelectedActivityId] = useState<string>(activity?.id || activities[0]?.id || '');
  const [manualTicket, setManualTicket] = useState<string>('');
  const [result, setResult] = useState<{ success: boolean; message: string; record?: any } | null>(null);
  const [cameraStatus, setCameraStatus] = useState('Requesting camera access…');
  const [isVerifying, setIsVerifying] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);
  const verifyRef = useRef(verifyAttendanceByQr);
  const onSuccessRef = useRef(onSuccess);
  const payloadHandlerRef = useRef<(payload: string) => void>(() => undefined);

  verifyRef.current = verifyAttendanceByQr;
  onSuccessRef.current = onSuccess;

  const handlePayload = async (payload: string) => {
    setManualTicket(payload);
    setIsVerifying(true);
    const response = await verifyRef.current(payload, currentActivity?.id || selectedActivityId);
    setResult(response);
    setIsVerifying(false);
    if (response.success) {
      setTimeout(() => onSuccessRef.current?.(), 1500);
    }
  };
  payloadHandlerRef.current = (payload) => {
    void handlePayload(payload);
  };

  useEffect(() => {
    const videoElement = videoRef.current;
    if (!isOpen || !videoElement) return;

    let cancelled = false;
    let controls: { stop: () => void } | undefined;
    let hasScanned = false;
    const reader = new BrowserQRCodeReader();
    setCameraStatus('Requesting camera access…');

    reader
      .decodeFromVideoDevice(undefined, videoElement, (decoded, _error, scannerControls) => {
        controls = scannerControls;
        if (cancelled || hasScanned || !decoded) return;

        hasScanned = true;
        scannerControls.stop();
        setCameraStatus('QR code detected. Verifying…');
        payloadHandlerRef.current(decoded.getText());
      })
      .then((scannerControls) => {
        controls = scannerControls;
        if (cancelled) {
          scannerControls.stop();
          return;
        }
        setCameraStatus('Camera ready. Point it at a QR code.');
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        const details = error instanceof Error ? error.message : 'Camera permission was denied.';
        setCameraStatus(`Camera unavailable: ${details}`);
      });

    return () => {
      cancelled = true;
      controls?.stop();
    };
  }, [isOpen]);

  if (!isOpen) return null;

  const currentActivity = activities.find((a) => a.id === selectedActivityId) || activity || activities[0];
  const assignedParolees = users.filter((u) => u.role === 'parolee' && currentActivity?.assignedParoleeIds.includes(u.id));

  const handleSimulatedScan = async (paroleeId: string) => {
    const payload = JSON.stringify({
      ticketId: `AT-2026-${Math.floor(1000 + Math.random() * 9000)}`,
      paroleeId,
      activityId: currentActivity?.id || selectedActivityId,
      timestamp: new Date().toISOString(),
    });
    await handlePayload(payload);
  };

  const handleManualSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!manualTicket.trim() || isVerifying) return;
    await handlePayload(manualTicket.trim());
  };

  return (
    <div className="fixed inset-0 z-50 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4">
      <div className="bg-white rounded-2xl max-w-lg w-full shadow-2xl border border-slate-200 overflow-hidden animate-in fade-in zoom-in-95 duration-150">
        {/* Header */}
        <div className="bg-[#1565C0] text-white px-6 py-4 flex items-center justify-between">
          <div className="flex items-center gap-2.5">
            <div className="p-2 rounded-lg bg-white/10">
              <QrCode className="w-5 h-5 text-blue-200" />
            </div>
            <div>
              <h3 className="font-semibold text-base">QR Attendance Scanner</h3>
              <p className="text-xs text-blue-100">Scan or simulate parolee attendance check-in</p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 rounded-lg text-white/80 hover:text-white hover:bg-white/10 transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        <div className="p-6 space-y-5">
          {/* Activity Selector */}
          <div>
            <label className="block text-xs font-semibold uppercase tracking-wider text-slate-500 mb-1.5">
              Target Activity / Session
            </label>
            <select
              value={selectedActivityId}
              onChange={(e) => setSelectedActivityId(e.target.value)}
              className="w-full text-xs sm:text-sm font-medium px-3.5 py-2.5 bg-slate-50 border border-slate-300 rounded-xl focus:ring-2 focus:ring-blue-500 focus:outline-hidden"
            >
              {activities.map((act) => (
                <option key={act.id} value={act.id}>
                  {act.title} ({act.status})
                </option>
              ))}
            </select>
          </div>

          {/* Camera QR scanner */}
          <div className="relative rounded-2xl bg-slate-950 p-6 flex flex-col items-center justify-center text-center overflow-hidden border border-slate-800">
            {/* Viewfinder brackets */}
            <div className="relative w-44 h-44 border-2 border-blue-400/80 rounded-2xl flex flex-col items-center justify-center p-4 bg-blue-950/20 overflow-hidden">
              <video
                ref={videoRef}
                autoPlay
                muted
                playsInline
                aria-label="Camera preview for QR scanning"
                className="absolute inset-0 w-full h-full object-cover"
              />
              <div className="absolute inset-0 border-4 border-slate-950/30 rounded-xl pointer-events-none" />
              {!cameraStatus.startsWith('Camera ready') && (
                <div className="absolute inset-0 flex items-center justify-center bg-slate-950/60 pointer-events-none">
                  <Camera className="w-10 h-10 text-blue-300 animate-pulse" />
                </div>
              )}
              {/* Laser animation bar */}
              <div className="absolute left-2 right-2 top-1/2 h-0.5 bg-gradient-to-r from-transparent via-cyan-400 to-transparent shadow-[0_0_8px_#38bdf8] animate-bounce pointer-events-none" />
            </div>
            <p className="text-xs text-slate-300 mt-3">{cameraStatus}</p>
          </div>

          {/* Result Alert */}
          {result && (
            <div
              className={`p-3.5 rounded-xl border flex items-start gap-3 ${
                result.success
                  ? 'bg-emerald-50 border-emerald-200 text-emerald-800'
                  : 'bg-rose-50 border-rose-200 text-rose-800'
              }`}
            >
              {result.success ? (
                <CheckCircle2 className="w-5 h-5 text-emerald-600 shrink-0 mt-0.5" />
              ) : (
                <AlertCircle className="w-5 h-5 text-rose-600 shrink-0 mt-0.5" />
              )}
              <div className="text-xs">
                <p className="font-semibold">{result.success ? 'Attendance Verified' : 'Check-in Error'}</p>
                <p className="mt-0.5">{result.message}</p>
              </div>
            </div>
          )}

          {/* Local-only simulation remains available for the built-in demo accounts. */}
          {canQuickSwitchRole && <div>
            <div className="flex items-center justify-between mb-2">
              <span className="text-xs font-semibold text-slate-500 uppercase tracking-wider flex items-center gap-1.5">
                <Sparkles className="w-3.5 h-3.5 text-amber-500" /> Quick Simulate Scan (Assigned Parolees)
              </span>
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              {assignedParolees.map((p) => {
                const isCompleted = currentActivity?.completedParoleeIds.includes(p.id);
                return (
                  <button
                    key={p.id}
                    onClick={() => handleSimulatedScan(p.id)}
                    className={`flex items-center justify-between p-2.5 rounded-xl text-xs font-medium border text-left transition-colors ${
                      isCompleted
                        ? 'bg-emerald-50/70 border-emerald-200 text-emerald-800'
                        : 'bg-slate-50 hover:bg-blue-50 border-slate-200 hover:border-blue-300 text-slate-800'
                    }`}
                  >
                    <div className="truncate pr-2">
                      <p className="font-semibold truncate">{p.fullName}</p>
                      <p className="text-[10px] text-slate-500">{p.caseNumber || 'Parolee'}</p>
                    </div>
                    {isCompleted ? (
                      <span className="text-[10px] font-semibold text-emerald-700 px-1.5 py-0.5 rounded-md bg-emerald-100">
                        Checked In
                      </span>
                    ) : (
                      <span className="text-[10px] font-semibold text-blue-700 px-1.5 py-0.5 rounded-md bg-blue-100">
                        Scan QR
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>}

          {/* Manual Ticket ID input fallback */}
          <form onSubmit={handleManualSubmit} className="pt-2 border-t border-slate-100">
            <label className="block text-xs font-semibold text-slate-500 uppercase tracking-wider mb-1.5">
              Paste full QR payload
            </label>
            <div className="flex gap-2">
              <input
                type="text"
              placeholder='{"t":"…","a":"…"}'
                value={manualTicket}
                onChange={(e) => setManualTicket(e.target.value)}
                className="flex-1 text-xs px-3.5 py-2 bg-slate-50 border border-slate-300 rounded-xl focus:ring-2 focus:ring-blue-500 focus:outline-hidden"
                disabled={isVerifying}
              />
              <button
                type="submit"
                disabled={isVerifying}
                className="px-4 py-2 bg-slate-800 hover:bg-slate-900 text-white rounded-xl text-xs font-semibold transition-colors disabled:opacity-50"
              >
                {isVerifying ? 'Saving…' : 'Verify'}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
};

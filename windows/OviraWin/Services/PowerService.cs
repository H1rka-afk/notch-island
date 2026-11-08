using System;
using System.Windows;
using Windows.System.Power;

namespace Ovira.Services
{
    public enum PowerEvent { Plugged, Unplugged, Low, Critical }

    // Battery and charger. On a desktop without a battery nothing happens.
    public sealed class PowerService
    {
        public event Action<PowerEvent, int>? Changed;      // event, percent

        private bool _onPower;
        private int _lastWarned = 101;

        public bool HasBattery => PowerManager.BatteryStatus != BatteryStatus.NotPresent;
        public int Percent => PowerManager.RemainingChargePercent;
        public bool Charging => PowerManager.BatteryStatus == BatteryStatus.Charging;
        public bool OnPower => PowerManager.PowerSupplyStatus != PowerSupplyStatus.NotPresent;

        public void Start()
        {
            try
            {
                _onPower = OnPower;
                PowerManager.PowerSupplyStatusChanged += (_, _) => OnUi(CheckSupply);
                PowerManager.RemainingChargePercentChanged += (_, _) => OnUi(CheckLevel);
                PowerManager.BatteryStatusChanged += (_, _) => OnUi(CheckSupply);
            }
            catch { }
        }

        private static void OnUi(Action action) => Application.Current?.Dispatcher.BeginInvoke(action);

        private void CheckSupply()
        {
            if (!HasBattery) return;
            var now = OnPower;
            if (now == _onPower) return;
            _onPower = now;
            if (now) _lastWarned = 101;
            Changed?.Invoke(now ? PowerEvent.Plugged : PowerEvent.Unplugged, Percent);
        }

        private void CheckLevel()
        {
            if (!HasBattery || OnPower) return;
            var p = Percent;
            if (p <= 10 && _lastWarned > 10) { _lastWarned = 10; Changed?.Invoke(PowerEvent.Critical, p); }
            else if (p <= 20 && _lastWarned > 20) { _lastWarned = 20; Changed?.Invoke(PowerEvent.Low, p); }
        }
    }
}

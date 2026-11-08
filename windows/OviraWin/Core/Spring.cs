using System;

namespace Ovira.Core
{
    // A damped spring like SwiftUI's .spring(response:dampingFraction:) —
    // the same feel as the Mac island. response = seconds per oscillation,
    // damping 1 = no overshoot, < 1 = a little bounce.
    public sealed class Spring
    {
        public double Value;
        public double Target;
        public double Velocity;
        private double _response = 0.48;
        private double _damping = 0.76;

        public Spring(double value) { Value = value; Target = value; }

        public void To(double target, double response, double damping)
        {
            Target = target;
            _response = Math.Max(0.05, response);
            _damping = Math.Max(0.05, damping);
        }

        public void Snap(double value) { Value = value; Target = value; Velocity = 0; }

        public bool Settled => Math.Abs(Value - Target) < 0.02 && Math.Abs(Velocity) < 0.05;

        // Returns true while still moving.
        public bool Step(double dt)
        {
            if (Settled) { Value = Target; Velocity = 0; return false; }
            double k = Math.Pow(2 * Math.PI / _response, 2);
            double c = 4 * Math.PI * _damping / _response;
            // Small fixed sub-steps keep it stable on slow frames.
            int steps = Math.Max(1, (int)Math.Ceiling(dt / (1.0 / 240)));
            double h = dt / steps;
            for (int i = 0; i < steps; i++)
            {
                double a = -k * (Value - Target) - c * Velocity;
                Velocity += a * h;
                Value += Velocity * h;
            }
            return true;
        }
    }

    // Shared timings — one set of motions for every island (as on the Mac).
    public static class Motion
    {
        public const double GrowResponse = 0.48, GrowDamping = 0.76;
        public const double ShrinkResponse = 0.42, ShrinkDamping = 1.0;
        public const double PeekResponse = 0.3, PeekDamping = 0.7;
    }
}

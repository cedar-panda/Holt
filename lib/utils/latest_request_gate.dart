/// Prevents an older asynchronous request from overwriting newer UI state.
class LatestRequestGate {
  int _generation = 0;

  int begin() => ++_generation;

  bool isCurrent(int generation) => generation == _generation;

  void invalidate() {
    _generation++;
  }
}

module game.cvars;

struct CVars {
	double debugOctree = 0; // > 0 if octree should be debugged, <= 0 if not
	double debugObjects = 0; // > 0 if objects should be debugged, <= if not
  double debugAiming = 0; // > 0 to enable debugging of aiming
}
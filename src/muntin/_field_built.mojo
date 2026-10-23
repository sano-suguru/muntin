"""`_FieldBuilt`: the types the storage module may build field by field
without running an initializer (M3-061, M3-082). Only `RouteValues` and
`JsonFields` refine it (the confinement step of `scripts/check.sh`), so
conforming to either is the consent that `__init__` never runs."""


trait _FieldBuilt(Deinitable, Movable):
    pass

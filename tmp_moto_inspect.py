import moto
import pkgutil
print('moto version', moto.__version__)
print('has attr autoscaling', hasattr(moto, 'autoscaling'))
print('has attr rds', hasattr(moto, 'rds'))
print('moto submodules', [m.name for m in pkgutil.iter_modules(moto.__path__) if 'auto' in m.name or 'rds' in m.name])
try:
    import moto.autoscaling as ma
    print('autoscaling module attrs', [n for n in dir(ma) if 'mock' in n.lower()][:50])
except Exception as e:
    print('autoscaling import error', e)
try:
    import moto.rds as mr
    print('rds module attrs', [n for n in dir(mr) if 'mock' in n.lower()][:50])
except Exception as e:
    print('rds import error', e)

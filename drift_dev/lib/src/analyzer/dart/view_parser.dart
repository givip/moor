part of 'parser.dart';

/// Parses a [MoorView] from a Dart class.
class ViewParser {
  final MoorDartParser base;

  ViewParser(this.base);

  Future<MoorView?> parseView(
      ClassElement element, List<MoorTable> tables) async {
    final name = await _parseViewName(element);
    final columns = (await _parseColumns(element)).toList();
    final staticReferences =
        (await _parseStaticReferences(element, tables)).toList();
    final dataClassInfo = _readDataClassInformation(columns, element);
    final query = await _parseQuery(element, staticReferences, columns);

    final view = MoorView(
      declaration: DartViewDeclaration(element, base.step.file),
      name: name,
      dartTypeName: dataClassInfo.enforcedName,
      existingRowClass: dataClassInfo.existingClass,
      entityInfoName: '\$${element.name}View',
      staticReferences: staticReferences.map((ref) => ref.declaration).toList(),
      viewQuery: query,
    );

    view.columns = columns;
    return view;
  }

  _DataClassInformation _readDataClassInformation(
      List<MoorColumn> columns, ClassElement element) {
    DartObject? useRowClass;
    String? dataClassName;

    for (final annotation in element.metadata) {
      final computed = annotation.computeConstantValue();
      final annotationClass = computed!.type!.element!.name;

      if (annotationClass == 'DriftView') {
        dataClassName = computed.getField('dataClassName')?.toStringValue();
      } else if (annotationClass == 'UseRowClass') {
        useRowClass = computed;
      }
    }

    if (dataClassName != null && useRowClass != null) {
      base.step.reportError(ErrorInDartCode(
        message: "A table can't be annotated with both @DataClassName and "
            '@UseRowClass',
        affectedElement: element,
      ));
    }

    FoundDartClass? existingClass;
    String? constructorInExistingClass;
    bool? generateInsertable;

    var name = dataClassName ?? dataClassNameForClassName(element.name);

    if (useRowClass != null) {
      final type = useRowClass.getField('type')!.toTypeValue();
      constructorInExistingClass =
          useRowClass.getField('constructor')!.toStringValue()!;
      generateInsertable =
          useRowClass.getField('generateInsertable')!.toBoolValue()!;

      if (type is InterfaceType) {
        existingClass = FoundDartClass(type.element, type.typeArguments);
        name = type.element.name;
      } else {
        base.step.reportError(ErrorInDartCode(
          message: 'The @UseRowClass annotation must be used with a class',
          affectedElement: element,
        ));
      }
    }

    final verified = existingClass == null
        ? null
        : validateExistingClass(columns, existingClass,
            constructorInExistingClass!, generateInsertable!, base.step);
    return _DataClassInformation(name, verified);
  }

  Future<String> _parseViewName(ClassElement element) async {
    for (final annotation in element.metadata) {
      final computed = annotation.computeConstantValue();
      final annotationClass = computed!.type!.element!.name;

      if (annotationClass == 'DriftView') {
        final name = computed.getField('name')?.toStringValue();
        if (name != null) {
          return name;
        }
        break;
      }
    }

    return element.name.snakeCase;
  }

  Future<Iterable<MoorColumn>> _parseColumns(ClassElement element) async {
    final columnNames = element.allSupertypes
        .map((t) => t.element)
        .followedBy([element])
        .expand((e) => e.fields)
        .where((field) =>
            (isExpression(field.type) || isColumn(field.type)) &&
            field.getter != null &&
            !field.getter!.isSynthetic)
        .map((field) => field.name)
        .toSet();

    final fields = columnNames.map((name) {
      final getter = element.getGetter(name) ??
          element.lookUpInheritedConcreteGetter(name, element.library);
      return getter!.variable;
    }).toList();

    final results = await Future.wait(fields.map((field) async {
      final dartType = (field.type as InterfaceType).typeArguments[0];
      final typeName = dartType.element!.name!;
      final sqlType = _dartTypeToColumnType(typeName);

      if (sqlType == null) {
        final String errorMessage;
        if (typeName == 'dynamic') {
          errorMessage = 'You must specify Expression<?> type argument';
        } else {
          errorMessage =
              'Invalid Expression<?> type argument `$typeName` found. '
              'Must be one of: '
              'bool, String, int, DateTime, Uint8List, double';
        }
        throw analysisError(base.step, field, errorMessage);
      }

      final node =
          await base.loadElementDeclaration(field.getter!) as MethodDeclaration;
      final expression = (node.body as ExpressionFunctionBody).expression;

      return MoorColumn(
          type: sqlType,
          dartGetterName: field.name,
          name: ColumnName.implicitly(ReCase(field.name).snakeCase),
          nullable: dartType.nullabilitySuffix == NullabilitySuffix.question,
          generatedAs: ColumnGeneratedAs(expression.toString(), false));
    }).toList());

    return results.whereType();
  }

  ColumnType? _dartTypeToColumnType(String name) {
    return const {
      'bool': ColumnType.boolean,
      'String': ColumnType.text,
      'int': ColumnType.integer,
      'DateTime': ColumnType.datetime,
      'Uint8List': ColumnType.blob,
      'double': ColumnType.real,
    }[name];
  }

  Future<List<_TableReference>> _parseStaticReferences(
      ClassElement element, List<MoorTable> tables) async {
    return await Stream.fromIterable(element.allSupertypes
            .map((t) => t.element)
            .followedBy([element]).expand((e) => e.fields))
        .asyncMap((field) => _getStaticReference(field, tables))
        .where((ref) => ref != null)
        .cast<_TableReference>()
        .toList();
  }

  Future<_TableReference?> _getStaticReference(
      FieldElement field, List<MoorTable> tables) async {
    if (field.getter != null) {
      try {
        final node = await base.loadElementDeclaration(field.getter!);
        if (node is MethodDeclaration && node.body is EmptyFunctionBody) {
          final type = tables.firstWhereOrNull(
              (tbl) => tbl.fromClass!.name == node.returnType.toString());
          if (type != null) {
            final name = node.name.toString();
            final declaration = '${type.entityInfoName} get $name => '
                '_db.${type.dbGetterName};';
            return _TableReference(type, name, declaration);
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<ViewQueryInformation> _parseQuery(ClassElement element,
      List<_TableReference> references, List<MoorColumn> columns) async {
    final as =
        element.methods.where((method) => method.name == 'as').firstOrNull;

    if (as != null) {
      try {
        final node = await base.loadElementDeclaration(as);

        var target =
            ((node as MethodDeclaration).body as ExpressionFunctionBody)
                .expression as MethodInvocation;

        for (;;) {
          if (target.target == null) break;
          target = target.target as MethodInvocation;
        }

        if (target.methodName.toString() != 'select') {
          throw analysisError(
              base.step,
              element,
              'The `as()` query declaration must be started '
              'with `select(columns).from(table)');
        }

        final columnListLiteral =
            target.argumentList.arguments[0] as ListLiteral;
        final columnList =
            columnListLiteral.elements.map((col) => col.toString()).map((col) {
          final parts = col.split('.');
          if (parts.length > 1) {
            final reference =
                references.firstWhereOrNull((ref) => ref.name == parts[0]);
            if (reference == null) {
              throw analysisError(
                  base.step,
                  element,
                  'Table named `${parts[0]}` not found! Maybe not included in '
                  '@DriftDatabase or not belongs to this database');
            }
            final column = reference.table.columns
                .firstWhere((col) => col.dartGetterName == parts[1]);
            column.table = reference.table;
            return MapEntry(
                '${reference.name}.${column.dartGetterName}', column);
          }
          final column =
              columns.firstWhere((col) => col.dartGetterName == parts[0]);
          return MapEntry('${column.dartGetterName}', column);
        });
        final columnMap = Map.fromEntries(columnList);

        target = target.parent as MethodInvocation;
        if (target.methodName.toString() != 'from') {
          throw analysisError(
              base.step,
              element,
              'The `as()` query declaration must be started '
              'with `select(columns).from(table)');
        }

        final from = target.argumentList.arguments[0].toString();
        var query = '';

        if (target.parent is MethodInvocation) {
          target = target.parent as MethodInvocation;
          query = target.toString().substring(target.target!.toString().length);
        }

        return ViewQueryInformation(columnMap, from, query);
      } catch (e) {
        print(e);
        throw analysisError(
            base.step, element, 'Failed to parse view `as()` query');
      }
    }

    throw analysisError(base.step, element, 'Missing `as()` query declaration');
  }
}

class _TableReference {
  MoorTable table;
  String name;
  String declaration;

  _TableReference(this.table, this.name, this.declaration);
}
